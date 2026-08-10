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

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chatclient-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bytes = try policy.serializedData(pretty: false)
    try bytes.write(to: dir.appendingPathComponent("policy.json"))
}

private struct ProjectedDispatchTestError: Error, LocalizedError {
    let errorDescription: String?
}

@Test
func projectedToolDispatchErrorPrefersUsefulSafeBoundedDescription() {
    let home = NSHomeDirectory()
    let message = SwiftNativeTurnEngine.projectedToolDispatchError(
        ProjectedDispatchTestError(
            errorDescription: "Could not read \(home)/Library/private.txt; token=secret-value"
        )
    )

    #expect(message.contains("~/Library/private.txt"))
    #expect(!message.contains(home))
    #expect(!message.contains("secret-value"))
    #expect(message.count <= 2_000)
}

@Test func searchKGToolFailsClosedOnCorruptCanonicalSQLite() async throws {
    let root = try makeTempRoot("search-kg-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
    let sqlitePath = memoryDirectory.appendingPathComponent("memory.sqlite")
    let corruptBytes = Data("not a sqlite database; stale JSON must never impersonate success".utf8)
    try corruptBytes.write(to: sqlitePath)
    try Data(#"{"entities":{"stale":{"id":"stale","name":"Needle","type":"fact"}},"edges":[]}"#.utf8)
        .write(to: memoryDirectory.appendingPathComponent("knowledge_graph.json"))
    let tools = SwiftToolDispatcher(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await tools.dispatch(
            tool: "search_kg",
            input: ["query": .string("Needle")],
            surface: "chat"
        )
    }
    #expect(try Data(contentsOf: sqlitePath) == corruptBytes)
}

private final class StubRoutingForClient: ProviderRoutingProtocol, @unchecked Sendable {
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

private actor MacNotifyInputRecorder {
    private var recorded: [[String: JSONValue]] = []

    func append(_ input: [String: JSONValue]) {
        recorded.append(input)
    }

    func all() -> [[String: JSONValue]] {
        recorded
    }
}

private actor CodexWakeupInputRecorder {
    private var recorded: [[String: JSONValue]] = []

    func append(_ input: [String: JSONValue]) {
        recorded.append(input)
    }

    func all() -> [[String: JSONValue]] {
        recorded
    }
}

private final class FakeMacIntegrationBridgeForCodexMessage: MacIntegrationToolBridge, @unchecked Sendable {
    private let recorder = MacNotifyInputRecorder()

    func macNotifyInputs() async -> [[String: JSONValue]] {
        await recorder.all()
    }

    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        await recorder.append(input)
        return .object([
            "status": .string("completed"),
            "posted": .bool(true),
            "delivery": .string("fake_macos_notification"),
            "notificationId": .string("fake-notification-id"),
        ])
    }
    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailSend(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicControl(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailReply(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue { stub() }

    private func stub() -> JSONValue {
        .object(["status": .string("stubbed")])
    }
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

private actor CognitiveEventCapture: CognitiveEventObserving {
    private var events: [CognitiveEvent] = []

    func observe(_ event: CognitiveEvent) async {
        events.append(event)
    }

    func all() -> [CognitiveEvent] {
        events
    }
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

private final class ModelCapturingLLM: LLMClient, @unchecked Sendable {
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

private final class ToolSchemaCapturingLLM: LLMClient, @unchecked Sendable {
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

private final class StructuredStreamingScriptLLM: LLMClient, @unchecked Sendable {
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

private final class ScriptedTextStreamingLLM: StreamingLLMClient, @unchecked Sendable {
    struct RouteCall: Sendable {
        let model: String?
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

private final class SchemaBackedToolDispatch: ToolDispatchClient, @unchecked Sendable {
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

private func makeEngine(
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
        turnTraceBus: turnTraceBus
    )
}

private func readJSONL(_ root: URL, sessionId: String) -> [[String: Any]] {
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

private func writeMessagesJSONL(_ root: URL, sessionId: String, lines: [String]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
                  .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: path, atomically: true, encoding: .utf8)
}

private func writeChatSessionsJSON(_ root: URL, sessions: [[String: String]]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rows = sessions.map { session -> JSONValue in
        .object(session.mapValues { .string($0) })
    }
    let data = try JSONValue.array(rows).serializedData(pretty: false)
    try data.write(to: dir.appendingPathComponent("sessions.json"))
}

private func chatMessageLine(
    id: String = UUID().uuidString,
    role: String,
    content: String,
    createdAt: String
) throws -> String {
    let data = try JSONValue.object([
        "id": .string(id),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string(createdAt),
    ]).serializedData(pretty: false)
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func writeMarketSecrets(_ root: URL) throws {
    let dir = root.appendingPathComponent("secrets", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
    {
      "_about": "test market config",
      "sources": {
        "finnhub": {"enabled": true, "key": "FINNHUB_TEST_KEY_NEVER_RETURN"},
        "coingecko": {"enabled": true},
        "fred": {"enabled": false, "key": "FRED_TEST_KEY_NEVER_RETURN"}
      },
      "watchlists": {
        "equities": {"symbols": ["SPY", "AAPL", "NVDA"]},
        "crypto": ["BTC-USD", "ETH-USD"]
      },
      "chat_binding": {"channel": "telegram"}
    }
    """.write(to: dir.appendingPathComponent("markets.json"), atomically: true, encoding: .utf8)
    try """
    {
      "_about": "test tradingview config",
      "plan": "pro",
      "capabilities": ["custom watchlist read", "scanner quote/technical snapshot"],
      "sessionid": "TV_SESSION_NEVER_RETURN",
      "sessionid_sign": "TV_SESSION_SIGN_NEVER_RETURN",
      "auth_token": "TV_AUTH_TOKEN_NEVER_RETURN",
      "jwt_expires_at": "2026-03-19T19:53:37Z",
      "watchlist_endpoint": "https://www.tradingview.com/api/v1/symbols_list/custom/",
      "scanner_endpoint": "https://scanner.tradingview.com/global/scan"
    }
    """.write(to: dir.appendingPathComponent("tradingview.json"), atomically: true, encoding: .utf8)
}

// MARK: - Tests

@Test
func swiftToolDispatcher_surfaces_mcp_names_and_schemas() async throws {
    let root = try makeTempRoot("mcp-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let mcp = root.appendingPathComponent("mcp", isDirectory: true)
    let cache = mcp.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try """
    [
      {"id":"local","name":"Local MCP","transport":"stdio","command":"/bin/echo","status":"ready","riskClass":"network_read"},
      {"id":"nativeagent-internal","name":"NativeAgent Internal MCP","transport":"native","status":"ready","riskClass":"app_data_read"}
    ]
    """.write(to: mcp.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
    try """
    {
      "local":{"tools":[
        {"name":"search","description":"Search through MCP."},
        {"name":"lookup","description":"Lookup with typed args.",
         "inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}
      ]},
      "nativeagent-internal":{"tools":[
        {"name":"capabilities.summary","description":"Internal capability summary."}
      ]}
    }
    """.write(to: cache.appendingPathComponent("tools.json"), atomically: true, encoding: .utf8)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("mcp__local__search"))
    // Raw compatibility remains available to the Tools/MCP UI and external
    // clients, even though ordinary model turns should not be offered a
    // duplicate self-MCP route.
    let internalName = "mcp__nativeagent-internal__capabilities.summary"
    #expect(names.contains(internalName))
    #expect(MCPToolBridge.listMCPToolNames(dataRoot: root).contains(internalName))

    let schemas = try await tools.listAvailableToolSchemas()
    #expect(!schemas.contains { $0.name == internalName })
    // No inputSchema in the cache row → permissive fallback object.
    let schema = try #require(schemas.first(where: { $0.name == "mcp__local__search" }))
    #expect(schema.description == "Search through MCP.")
    let parsed = try JSONValue.parse(schema.parametersJSON)
    guard case .object(let obj) = parsed else {
        Issue.record("MCP schema should be object")
        return
    }
    #expect(obj["type"] == .string("object"))
    #expect(obj["additionalProperties"] == .bool(true))

    // Cache row carries a real inputSchema → surfaced verbatim to the LLM
    // (NOT replaced by the permissive fallback).
    let typed = try #require(schemas.first(where: { $0.name == "mcp__local__lookup" }))
    let typedParsed = try JSONValue.parse(typed.parametersJSON)
    guard case .object(let typedObj) = typedParsed else {
        Issue.record("typed MCP schema should be object")
        return
    }
    #expect(typedObj["type"] == .string("object"))
    #expect(typedObj["required"] == .array([.string("q")]))
    guard case .object(let props)? = typedObj["properties"],
          case .object(let qProp)? = props["q"] else {
        Issue.record("typed MCP schema should carry properties.q")
        return
    }
    #expect(qProp["type"] == .string("string"))
    #expect(typedObj["additionalProperties"] == nil)

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let catalogObject) = catalog,
          case .array(let available)? = catalogObject["available_tools"] else {
        Issue.record("expected compact model-visible catalog")
        return
    }
    #expect(!available.contains(.string(internalName)))

    let rawResult = try await SwiftNativeMCPDispatcher(root: root).callToolLive(
        forServer: "nativeagent-internal",
        toolName: "capabilities.summary"
    )
    guard case .object(let rawObject) = rawResult else {
        Issue.record("expected raw native MCP result")
        return
    }
    #expect(rawObject["status"] == .string("ok"))
}

@Test
func mcpToolBridge_effectiveRisk_uses_tool_risk_and_fails_closed_for_external_missing_risk() async throws {
    let root = try makeTempRoot("mcp-risk")
    defer { try? FileManager.default.removeItem(at: root) }
    let mcp = root.appendingPathComponent("mcp", isDirectory: true)
    let cache = mcp.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try """
    [
      {"id":"local","name":"Local MCP","transport":"stdio","command":"/bin/echo","status":"ready","riskClass":"network_read"},
      {"id":"nativeagent-internal","name":"NativeAgent Internal MCP","transport":"native","status":"ready","riskClass":"app_data_read"},
      {"id":"searxng-local","name":"SearXNG Local Search","transport":"http","endpoint":"http://127.0.0.1:8888","status":"ready","riskClass":"network_read"}
    ]
    """.write(to: mcp.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
    try """
    {
      "local":{"tools":[
        {"name":"graphql","description":"Mutating query.","risk_class":"external_write"},
        {"name":"search","description":"Missing risk."}
      ]},
      "nativeagent-internal":{"tools":[
        {"name":"agent.operating_map","description":"Internal read."}
      ]},
      "searxng-local":{"tools":[
        {"name":"search","description":"Built-in local search missing tool risk."}
      ]}
    }
    """.write(to: cache.appendingPathComponent("tools.json"), atomically: true, encoding: .utf8)

    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "local",
        toolName: "graphql",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "external_write")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "local",
        toolName: "search",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "approval_gated_missing_tool_risk")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "nativeagent-internal",
        toolName: "agent.operating_map",
        serverRiskClass: "app_data_read",
        dataRoot: root
    ) == "app_data_read")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "searxng-local",
        toolName: "search",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "network_read")
}

@Test
func mcpToolBridge_consentMustMatch_currentEffectiveRisk() async throws {
    let granted = MCPConsent(
        id: "local:search",
        serverId: "local",
        toolName: "search",
        risk: "app_data_read",
        status: "granted",
        grantedAt: "2026-06-05T00:00:00+00:00",
        updatedAt: "2026-06-05T00:00:00+00:00"
    )
    let revoked = MCPConsent(
        id: "local:search",
        serverId: "local",
        toolName: "search",
        risk: "app_data_read",
        status: "revoked",
        grantedAt: "2026-06-05T00:00:00+00:00",
        updatedAt: "2026-06-05T00:00:00+00:00"
    )

    #expect(MCPToolBridge.consent(granted, matchesCurrentEffectiveRisk: "app_data_read"))
    #expect(!MCPToolBridge.consent(granted, matchesCurrentEffectiveRisk: "external_write"))
    #expect(!MCPToolBridge.consent(revoked, matchesCurrentEffectiveRisk: "app_data_read"))
}

@Test
func swiftToolDispatcher_reports_swift_runtime_introspection_aliases() async throws {
    let root = try makeTempRoot("introspect")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let agent = try await tools.dispatch(tool: "agent_introspect", input: [:], surface: "chat")
    guard case .object(let agentObj) = agent else {
        Issue.record("expected agent_introspect object")
        return
    }
    #expect(agentObj["runtime"] == .string("swift-native"))
    #expect(agentObj["python_daemon"] == .string("retired"))
    guard case .array(let activeTools)? = agentObj["active_tools"] else {
        Issue.record("expected active tool list")
        return
    }
    #expect(activeTools.contains(.string("agent_introspect")))
    #expect(!activeTools.contains(.string("daemon_introspect")))
    #expect(agentObj["active_tool_count"] == .int(Int64(activeTools.count)))
    guard case .int(let availableCount)? = agentObj["available_tool_count"] else {
        Issue.record("expected available tool count")
        return
    }
    #expect(availableCount >= Int64(activeTools.count))
    #expect(agentObj["lazy_loading"] != nil)

    let compat = try await tools.dispatch(tool: "daemon_introspect", input: [:], surface: "chat")
    guard case .object(let compatObj) = compat else {
        Issue.record("expected daemon_introspect object")
        return
    }
    #expect(compatObj["runtime"] == .string("swift-native"))
    #expect(compatObj["invoked_as"] == .string("daemon_introspect"))
}

@Test
func swiftToolDispatcher_tool_catalog_includes_swift_aliases() async throws {
    let root = try makeTempRoot("catalog")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let compact = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let compactObj) = compact else {
        Issue.record("expected compact tool_catalog object")
        return
    }
    #expect(compactObj["catalog_detail"] == .string("compact"))
    #expect(compactObj["tools"] == .array([]))
    #expect(compactObj["tool_groups"] != nil)

    let catalog = try await tools.dispatch(
        tool: "tool_catalog",
        input: ["detail": .string("full")],
        surface: "chat"
    )
    guard case .object(let obj) = catalog else {
        Issue.record("expected tool_catalog object")
        return
    }
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["catalog_detail"] == .string("full"))
    // 2026-06-08 lazy-tool-skill-loading: tool_catalog now reports lazy_load=true
    // (it WAS false in the eager-everything-on era). The test was stale.
    #expect(obj["lazy_load"] == .bool(true))
    #expect(obj["builder_mode"] == .string("policy_locked"))
    #expect(obj["full_mac_active"] == .bool(false))
    guard case .array(let names)? = obj["available_tools"] else {
        Issue.record("expected available_tools")
        return
    }
    #expect(names.contains(.string("tool_catalog")))
    #expect(names.contains(.string("list_tools")))
    #expect(names.contains(.string("tool_load")))
    #expect(names.contains(.string("recall_search")))
    #expect(names.contains(.string("recall_memory")))
    #expect(names.contains(.string("search_chat_history")))
    #expect(names.contains(.string("session_search")))
    #expect(names.contains(.string("context_lookup")))
    #expect(names.contains(.string("scratchpad_read")))
    #expect(names.contains(.string("recent_trace_summary")))
    #expect(names.contains(.string("market_status")))
    #expect(names.contains(.string("market_watchlists")))
    #expect(names.contains(.string("tradingview_watchlist")))
    #expect(names.contains(.string("market_quote")))
    #expect(names.contains(.string("persona_read")))
    #expect(names.contains(.string("persona_write")))
    #expect(names.contains(.string("persona_append_section")))
    guard case .array(let rows)? = obj["tools"] else {
        Issue.record("expected tool catalog rows")
        return
    }
    for row in rows {
        guard case .object(let rowObj) = row else {
            Issue.record("expected object tool row")
            continue
        }
        guard case .object(let parameters)? = rowObj["parameters"] else {
            Issue.record("expected parameter schema for every catalog row")
            continue
        }
        #expect(parameters["type"] == .string("object"))
        #expect(parameters["properties"] != nil)
        #expect(parameters["required"] != nil)
        #expect(rowObj["load_state"] != nil)
    }
}

@Test
func swiftToolDispatcher_alwaysOnCoreNames_staysWithinLazyLoadBudget() async throws {
    let alwaysOn = SwiftToolDispatcher.alwaysOnCoreNames
    // Budget guard for the hot lazy-load-exempt core. Bumped 20→21 when
    // commit_memory (Agent's memory WRITE path) was restored: the write must
    // be always-loaded so the model can save a fact mid-turn without a
    // tool_load dance, symmetric with the always-on recall_memory.
    // Bumped 21→22 for desk_read (2026-06-29, User's pull-to-retrieve flow:
    // "what's on the desk" must work regardless of phrasing — the nine desk
    // mutations stay lazy).
    // Bumped 22→23 for ContextFlow's context_expand. Its schema is omitted on
    // ordinary turns and appears only when that turn offers a pinned pointer.
    // Canonical-only hot names: compatibility aliases remain catalog-visible
    // but no longer tax every ordinary provider request.
    #expect(alwaysOn.count <= 24)
    #expect(alwaysOn.contains("tool_load"))
    #expect(alwaysOn.contains("tool_result_page"))
    #expect(alwaysOn.contains("search_chat_history"))
    #expect(!alwaysOn.contains("session_search"))
    #expect(alwaysOn.contains("claude_message"))
    #expect(!alwaysOn.contains("invoke_claude"))
    #expect(alwaysOn.contains("codex_message"))
    #expect(!alwaysOn.contains("invoke_codex"))
    #expect(alwaysOn.contains("recall_memory"))
    #expect(!alwaysOn.contains("recall_search"))
    #expect(!alwaysOn.contains("list_tools"))
    #expect(!alwaysOn.contains("daemon_introspect"))
    #expect(alwaysOn.contains("commit_memory"))
}

@Test
func swiftToolDispatcher_codexMessageQueuesInboxAndPostsMacNotification() async throws {
    let root = try makeTempRoot("codex-message")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let bridge = FakeMacIntegrationBridgeForCodexMessage()
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        macIntegrationBridge: bridge,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: true,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object([
                "status": .string("sent"),
                "delivery": .string("fake_codex_thread_wakeup"),
                "threadId": .string("thread-test"),
            ])
        }
    )

    let route = ChatToolSessionContext.ReplyRoute(
        surface: "telegram",
        destinationId: "123456",
        correlationId: "telegram-update-7"
    )
    let result = try await ChatToolSessionContext.$replyRoute.withValue(route) {
        try await tools.dispatch(
            tool: "codex_message",
            input: [
                "text": JSONValue.string("hello Codex from Agent"),
                "priority": JSONValue.string("important"),
                "topic": JSONValue.string("nativeagent-test"),
                "model": JSONValue.string("gpt-5.6-terra"),
                "reasoning_effort": JSONValue.string("ultra"),
                "fast": JSONValue.bool(true),
                "__session_id": JSONValue.string("session-test"),
            ],
            surface: "telegram"
        )
    }

    guard case .object(let obj) = result else {
        Issue.record("codex_message should return an object")
        return
    }
    #expect(obj["status"] == JSONValue.string("queued"))
    #expect(obj["priority"] == JSONValue.string("important"))
    #expect(obj["conversationId"] == JSONValue.string("codex:thread-test"))
    #expect(obj["replyWith"] == JSONValue.string("codex_message"))

    guard let filePathValue = obj["filePath"],
          case .string(let filePath) = filePathValue else {
        Issue.record("codex_message should return filePath")
        return
    }
    let inboxURL = configRoot
        .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        .appendingPathComponent("codex-inbox.jsonl")
    #expect(filePath == inboxURL.path)

    let raw = try String(contentsOf: inboxURL, encoding: .utf8)
    let lines = raw.split(separator: "\n")
    #expect(lines.count == 1)
    guard let firstLine = lines.first,
          case .object(let row) = try JSONValue.parse(Data(firstLine.utf8)) else {
        Issue.record("codex_message inbox row should be parseable JSON object")
        return
    }
    #expect(row["from"] == JSONValue.string("assistant"))
    guard case .string(let rowId)? = row["id"],
          case .string(let rowMessageId)? = row["messageId"] else {
        Issue.record("codex_message inbox row should include id and messageId")
        return
    }
    #expect(rowMessageId == rowId)
    #expect(row["priority"] == JSONValue.string("important"))
    #expect(row["topic"] == JSONValue.string("nativeagent-test"))
    #expect(row["text"] == JSONValue.string("hello Codex from Agent"))
    #expect(row["sessionId"] == JSONValue.string("session-test"))
    #expect(row["model"] == JSONValue.string("gpt-5.6-terra"))
    #expect(row["reasoningEffort"] == JSONValue.string("ultra"))
    #expect(row["serviceTier"] == JSONValue.string("priority"))
    #expect(row["fast"] == JSONValue.bool(true))
    guard case .object(let rowOrigin)? = row["origin"] else {
        Issue.record("codex_message inbox row should preserve the reply route")
        return
    }
    #expect(rowOrigin["surface"] == JSONValue.string("telegram"))
    #expect(rowOrigin["destinationId"] == JSONValue.string("123456"))
    #expect(rowOrigin["correlationId"] == JSONValue.string("telegram-update-7"))
    #expect(row["read"] == JSONValue.bool(false))

    guard let notificationValue = obj["notification"],
          case .object(let notification) = notificationValue else {
        Issue.record("codex_message should include notification receipt")
        return
    }
    #expect(notification["status"] == JSONValue.string("completed"))
    #expect(notification["posted"] == JSONValue.bool(true))
    #expect(notification["delivery"] == JSONValue.string("fake_macos_notification"))
    #expect(notification["trigger"] == JSONValue.string("codex_message"))

    let notifyInputs = await bridge.macNotifyInputs()
    #expect(notifyInputs.count == 1)
    #expect(notifyInputs.first?["title"] == JSONValue.string("Important NativeAgent to Codex"))
    #expect(notifyInputs.first?["message"] == JSONValue.string("[nativeagent-test] hello Codex from Agent"))

    guard let wakeupValue = obj["wakeup"],
          case .object(let wakeupReceipt) = wakeupValue else {
        Issue.record("codex_message should include wakeup receipt")
        return
    }
    #expect(wakeupReceipt["status"] == JSONValue.string("sent"))
    #expect(wakeupReceipt["delivery"] == JSONValue.string("fake_codex_thread_wakeup"))
    #expect(wakeupReceipt["threadId"] == JSONValue.string("thread-test"))

    let wakeupInputs = await wakeup.all()
    #expect(wakeupInputs.count == 1)
    #expect(wakeupInputs.first?["text"] == JSONValue.string("hello Codex from Agent"))
    #expect(wakeupInputs.first?["priority"] == JSONValue.string("important"))
    #expect(wakeupInputs.first?["topic"] == JSONValue.string("nativeagent-test"))
    #expect(wakeupInputs.first?["source"] == JSONValue.string("codex_message"))
    #expect(wakeupInputs.first?["sessionId"] == JSONValue.string("session-test"))
    #expect(wakeupInputs.first?["model"] == JSONValue.string("gpt-5.6-terra"))
    #expect(wakeupInputs.first?["reasoningEffort"] == JSONValue.string("ultra"))
    #expect(wakeupInputs.first?["serviceTier"] == JSONValue.string("priority"))
    #expect(wakeupInputs.first?["fast"] == JSONValue.bool(true))
    #expect(wakeupInputs.first?["threadId"] == nil)
    #expect(wakeupInputs.first?["origin"] == row["origin"])
}

@Test
func swiftToolDispatcher_codexConversationReferenceResumesExactThread() async throws {
    let root = try makeTempRoot("codex-conversation-reply")
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent"), "threadId": .string("thread-original")])
        }
    )

    let result = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Please adjust the same implementation."),
            "conversation_id": .string("codex:thread-original"),
            "message_id": .string("codex-reply-1"),
            "__session_id": .string("agent-origin-session"),
        ],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("codex_message reply should return an object")
        return
    }
    #expect(object["conversationId"] == .string("codex:thread-original"))
    let payloads = await wakeup.all()
    #expect(payloads.count == 1)
    #expect(payloads[0]["threadId"] == .string("thread-original"))
    #expect(payloads[0]["sessionId"] == .string("agent-origin-session"))

    let retargetedDuplicate = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Please adjust the same implementation."),
            "conversation_id": .string("codex:different-thread"),
            "message_id": .string("codex-reply-1"),
            "__session_id": .string("agent-origin-session"),
        ],
        surface: "chat"
    )
    guard case .object(let retargetedObject) = retargetedDuplicate else {
        Issue.record("retargeted duplicate should return an object")
        return
    }
    #expect(retargetedObject["reason"] == .string("message_id_conflict"))
    #expect(await wakeup.all().count == 1)

    let mismatch = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Wrong worker must not run."),
            "conversation_id": .string("claude:wake-parity"),
        ],
        surface: "chat"
    )
    guard case .object(let mismatchObject) = mismatch else {
        Issue.record("mismatched conversation should return an object")
        return
    }
    #expect(mismatchObject["status"] == .string("failed"))
    #expect(mismatchObject["reason"] == .string("conversation_agent_mismatch"))
    #expect(await wakeup.all().count == 1)

    let malformed = try await tools.dispatch(
        tool: "codex_message",
        input: ["text": .string("Malformed reference must not start fresh."), "conversation_id": .int(42)],
        surface: "chat"
    )
    guard case .object(let malformedObject) = malformed else {
        Issue.record("malformed conversation should return an object")
        return
    }
    #expect(malformedObject["reason"] == .string("invalid_conversation_id"))
    #expect(await wakeup.all().count == 1)
}

@Test
func swiftToolDispatcher_claudeMessageQueuesInboxAndWakesClaudeSession() async throws {
    let root = try makeTempRoot("claude-message-wakeup")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object([
                "status": .string("sent"),
                "delivery": .string("fake_claude_thread_wakeup"),
                "topicSlug": .string("wake-parity"),
            ])
        }
    )

    let input: [String: JSONValue] = [
        "text": .string("write the parity proof artifact"),
        "priority": .string("important"),
        "topic": .string("wake parity"),
        "message_id": .string("claude-wake-1"),
        "__session_id": .string("agent-session-1"),
    ]
    let result = try await tools.dispatch(tool: "claude_message", input: input, surface: "chat")

    guard case .object(let obj) = result else {
        Issue.record("claude_message should return an object")
        return
    }
    #expect(obj["status"] == JSONValue.string("queued"))
    #expect(obj["deduplicated"] == JSONValue.bool(false))
    #expect(obj["conversationId"] == JSONValue.string("claude:wake-parity"))
    #expect(obj["replyWith"] == JSONValue.string("claude_message"))

    guard let wakeupValue = obj["wakeup"], case .object(let receipt) = wakeupValue else {
        Issue.record("claude_message should carry a wakeup receipt")
        return
    }
    #expect(receipt["status"] == JSONValue.string("sent"))
    #expect(receipt["delivery"] == JSONValue.string("fake_claude_thread_wakeup"))

    let sent = await wakeup.all()
    #expect(sent.count == 1)
    #expect(sent.first?["messageId"] == JSONValue.string("claude-wake-1"))
    #expect(sent.first?["text"] == JSONValue.string("write the parity proof artifact"))
    #expect(sent.first?["priority"] == JSONValue.string("important"))
    #expect(sent.first?["topic"] == JSONValue.string("wake-parity"))
    #expect(sent.first?["source"] == JSONValue.string("claude_message"))
    #expect(sent.first?["sessionId"] == JSONValue.string("agent-session-1"))
    guard case .string(let inboxPath)? = sent.first?["inboxPath"] else {
        Issue.record("wakeup payload should carry the durable inbox path")
        return
    }
    #expect(inboxPath == obj["filePath"].flatMap { value -> String? in
        guard case .string(let path) = value else { return nil }
        return path
    })

    // Replaying the same message_id must NOT double-wake her.
    let replay = try await tools.dispatch(tool: "claude_message", input: input, surface: "chat")
    guard case .object(let replayObj) = replay,
          case .object(let replayReceipt)? = replayObj["wakeup"] else {
        Issue.record("claude_message replay should return a wakeup receipt")
        return
    }
    #expect(replayObj["deduplicated"] == JSONValue.bool(true))
    #expect(replayReceipt["status"] == JSONValue.string("deduplicated"))
    #expect(await wakeup.all().count == 1)
}

@Test
func swiftToolDispatcher_claudeConversationReferenceResumesTopicPointer() async throws {
    let root = try makeTempRoot("claude-conversation-reply")
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        claudeMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let first = try await tools.dispatch(
        tool: "claude_message",
        input: ["text": .string("Start new work."), "message_id": .string("claude-first")],
        surface: "chat"
    )
    guard case .object(let firstObject) = first,
          case .string(let conversationId)? = firstObject["conversationId"] else {
        Issue.record("first claude_message should return a conversation reference")
        return
    }
    #expect(conversationId.hasPrefix("claude:conversation-"))

    _ = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Continue with one adjustment."),
            "conversation_id": .string(conversationId),
            "message_id": .string("claude-reply"),
        ],
        surface: "chat"
    )
    let payloads = await wakeup.all()
    #expect(payloads.count == 2)
    let referenceTopic = String(conversationId.dropFirst("claude:".count))
    #expect(payloads[0]["topic"] == .string(referenceTopic))
    #expect(payloads[1]["topic"] == .string(referenceTopic))

    let mismatch = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Conflicting topic must fail."),
            "conversation_id": .string(conversationId),
            "topic": .string("another-topic"),
        ],
        surface: "chat"
    )
    guard case .object(let mismatchObject) = mismatch else {
        Issue.record("topic mismatch should return an object")
        return
    }
    #expect(mismatchObject["reason"] == .string("conversation_topic_mismatch"))
    #expect(await wakeup.all().count == 2)
}

@Test
func swiftToolDispatcher_asyncBuilderMessagesFailBeforeQueueWithoutReturnBridge() async throws {
    for tool in ["codex_message", "claude_message"] {
        let root = try makeTempRoot("\(tool)-missing-return")
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let tools = SwiftToolDispatcher(dataRoot: root, agentBridgeConfigRoot: configRoot)
        let result = try await tools.dispatch(
            tool: tool,
            input: ["text": .string("round-trip probe")],
            surface: "chat"
        )
        guard case .object(let object) = result else {
            Issue.record("\(tool) should return an object")
            continue
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] == .string("return_bridge_unavailable"))
        #expect(object["detail"] == .string("token_missing"))
        #expect(object["fix"] == .string("Keep NativeAgent open and retry. The authenticated local return bridge starts automatically; Developer Mode is not required."))
        let inboxName = tool == "codex_message" ? "codex-nativeagent-bridge" : "claude-bridge"
        #expect(FileManager.default.fileExists(
            atPath: configRoot.appendingPathComponent(inboxName, isDirectory: true).path
        ) == false)
    }
}

/// Serialized on purpose: both tests below mutate PROCESS-WIDE environment
/// (the kill switch and the helper's test seams). Run in parallel, the kill
/// switch leaks into the end-to-end test and turns a real wake into
/// `skipped:disabled_by_environment` — which is exactly how this suite failed
/// the first time it ran.
@Suite("claude_message wakeup (environment-mutating)", .serialized)
struct ClaudeMessageWakeupEnvironmentTests {

@Test
func claudeMessageWakeupKillSwitchAndMissingHelperFailHonestly() async throws {
    let root = try makeTempRoot("claude-message-killswitch")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)

    // Kill switch wins even when a readable helper is configured.
    setenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED", "1", 1)
    defer { unsetenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED") }
    let helper = claudeWakeupHelperScriptURL()
    let disabledTools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: helper
    )
    let disabled = try await disabledTools.dispatch(
        tool: "claude_message",
        input: ["text": .string("kill switch check"), "message_id": .string("kill-switch-1")],
        surface: "chat"
    )
    guard case .object(let disabledObj) = disabled,
          case .object(let disabledReceipt)? = disabledObj["wakeup"] else {
        Issue.record("claude_message should carry a wakeup receipt when disabled")
        return
    }
    #expect(disabledObj["status"] == JSONValue.string("queued"))
    #expect(disabledReceipt["status"] == JSONValue.string("skipped"))
    #expect(disabledReceipt["reason"] == JSONValue.string("disabled_by_environment"))
    #expect(disabledReceipt["env"] == JSONValue.string("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"))

    // The inbox append still happened — the wakeup is additive, never a gate.
    let inboxURL = configRoot
        .appendingPathComponent("claude-bridge", isDirectory: true)
        .appendingPathComponent("claude-inbox.jsonl")
    #expect(FileManager.default.fileExists(atPath: inboxURL.path))

    unsetenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED")
    let missingTools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: root.appendingPathComponent("nope/claude_thread_wakeup.js")
    )
    let missing = try await missingTools.dispatch(
        tool: "claude_message",
        input: ["text": .string("missing helper check"), "message_id": .string("missing-helper-1")],
        surface: "chat"
    )
    guard case .object(let missingObj) = missing,
          case .object(let missingReceipt)? = missingObj["wakeup"] else {
        Issue.record("claude_message should carry a wakeup receipt when the helper is absent")
        return
    }
    #expect(missingReceipt["status"] == JSONValue.string("skipped"))
    #expect(missingReceipt["reason"] == JSONValue.string("helper_not_found"))
}

/// End-to-end across the language seam: the real Node helper runs with a fake
/// `claude` binary and a dry-run bridge, and its envelope has to arrive inside
/// the tool result. Build-green does not prove this path; running it does.
@Test
func claudeMessageRunsTheRealHelperEndToEnd() async throws {
    let helper = claudeWakeupHelperScriptURL()
    guard FileManager.default.isReadableFile(atPath: helper.path) else {
        Issue.record("script/claude_thread_wakeup.js is missing")
        return
    }
    let root = try makeTempRoot("claude-message-e2e")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let bridgeDir = root.appendingPathComponent("claude-bridge", isDirectory: true)
    try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
    let fakeClaude = root.appendingPathComponent("fake-claude.sh")
    try "#!/bin/sh\necho \"artifact written by the fake claude\"\n"
        .write(to: fakeClaude, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

    setenv("NATIVE_AGENT_CLAUDE_BRIDGE_DIR", bridgeDir.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN", fakeClaude.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_CWD", root.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_INLINE", "1", 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN", "1", 1)
    defer {
        unsetenv("NATIVE_AGENT_CLAUDE_BRIDGE_DIR")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CWD")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_INLINE")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN")
    }

    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: helper
    )
    let result = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("prove the wake path"),
            "topic": .string("Wake Parity"),
            "message_id": .string("e2e-wake-1"),
        ],
        surface: "chat"
    )

    guard case .object(let obj) = result,
          case .object(let receipt)? = obj["wakeup"] else {
        Issue.record("claude_message should carry the real helper's envelope")
        return
    }
    #expect(receipt["status"] == JSONValue.string("completed"))
    #expect(receipt["delivery"] == JSONValue.string("claude_thread_wakeup"))
    #expect(receipt["topicSlug"] == JSONValue.string("wake-parity"))
    #expect(receipt["messageId"] == JSONValue.string("e2e-wake-1"))
    #expect(receipt["helper"] == JSONValue.string(helper.path))

    // The would-be bridge text carries the reply and the loop guard.
    guard case .string(let wouldSend)? = receipt["wouldSendText"] else {
        Issue.record("dry-run helper should return the text it would post to Agent")
        return
    }
    #expect(wouldSend.contains("artifact written by the fake claude"))
    #expect(wouldSend.contains("Do NOT auto-fire another claude_message"))

    // And a durable receipt landed on disk.
    let deliveries = bridgeDir.appendingPathComponent("wake-deliveries.jsonl")
    let raw = try String(contentsOf: deliveries, encoding: .utf8)
    #expect(raw.contains("e2e-wake-1"))
}

}

private func claudeWakeupHelperScriptURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChatOrchestrationTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("script/claude_thread_wakeup.js")
        .standardizedFileURL
}

@Test
func swiftToolDispatcher_githubCommandMaySelectVerifiedCodexWorkspaceButOrdinaryChatCannot() async throws {
    let root = try makeTempRoot("codex-message-workspace")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let checkout = root.appendingPathComponent("target-checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("trusted github work"),
            "message_id": .string("github-workspace"),
            "working_directory": .string(checkout.path),
        ],
        surface: "github-command"
    )
    let denied = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("ordinary chat"),
            "message_id": .string("chat-workspace"),
            "working_directory": .string(checkout.path),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    #expect(inputs[0]["workingDirectory"] == .string(checkout.path))
    #expect(inputs[0]["executionProfile"] == .string("github-command-repository-network-v1"))
    guard case .object(let deniedObject) = denied else {
        Issue.record("ordinary chat should return a denial envelope")
        return
    }
    #expect(deniedObject["reason"] == .string("working_directory_outside_workspace_denied"))
}

@Test
func swiftToolDispatcher_fullMacChatPassesExplicitProjectToCodexAndClaude() async throws {
    let root = try makeTempRoot("full-mac-agent-bridge-cwd")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let project = root.appendingPathComponent("external-project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "shell_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ]))

    let codex = CodexWakeupInputRecorder()
    let claude = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codex.append(input)
            return .object(["status": .string("sent")])
        },
        claudeMessageWakeupOverride: { input in
            await claude.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let common: [String: JSONValue] = [
        "text": .string("inspect and build this project"),
        "working_directory": .string(project.path),
    ]
    _ = try await tools.dispatch(tool: "codex_message", input: common, surface: "chat")
    _ = try await tools.dispatch(tool: "claude_message", input: common, surface: "chat")

    let codexInputs = await codex.all()
    let claudeInputs = await claude.all()
    #expect(codexInputs.first?["workingDirectory"] == .string(project.path))
    #expect(claudeInputs.first?["cwd"] == .string(project.path))
}

@Test
func swiftToolDispatcher_asyncBuilderSchemasAdvertiseExplicitWorkingDirectory() throws {
    let dispatcher = SwiftToolDispatcher(dataRoot: FileManager.default.temporaryDirectory)
    for name in ["codex_message", "claude_message"] {
        let schema = try #require(
            dispatcher.builtInToolSchemas(includeFullMacFileTools: false).first { $0.name == name }
        )
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let root) = parsed,
              case .object(let properties)? = root["properties"] else {
            Issue.record("\(name) schema is malformed")
            return
        }
        #expect(properties["working_directory"] != nil)
    }
}

@Test
func swiftToolDispatcher_nonFullMacChatRejectsExplicitExternalBridgeProject() async throws {
    let root = try makeTempRoot("non-full-mac-agent-bridge-cwd")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let project = root.appendingPathComponent("external-project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let codex = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codex.append(input)
            return .object(["status": .string("sent")])
        }
    )
    let result = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("inspect this project"),
            "working_directory": .string(project.path),
        ],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("expected denial envelope")
        return
    }
    #expect(object["reason"] == .string("working_directory_outside_workspace_denied"))
    let dispatched = await codex.all()
    #expect(dispatched.isEmpty)
}

@discardableResult
private func runRepositoryTestGit(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// The `repository` opt-in is the whole point of the change: chat may name a
/// repo (never a path) and get a verified checkout + network profile, while a
/// same-named directory pointing at a DIFFERENT remote must never resolve.
@Test
func swiftToolDispatcher_codexMessageRepositoryResolvesOnlyVerifiedRemote() async throws {
    let root = try makeTempRoot("codex-message-repository")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let searchRoot = root.appendingPathComponent("Projects", isDirectory: true)

    // Decoy: right folder name, wrong remote.
    let decoy = searchRoot.appendingPathComponent("hermes-agent", isDirectory: true)
    // Real: different folder name, correct remote.
    let real = searchRoot.appendingPathComponent("hermes-agent-contrib", isDirectory: true)
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: decoy)
    try runRepositoryTestGit(["remote", "add", "origin", "https://github.com/someone/unrelated.git"], at: decoy)
    try runRepositoryTestGit(["init", "-q"], at: real)
    try runRepositoryTestGit(["remote", "add", "origin", "https://github.com/NousResearch/hermes-agent.git"], at: real)

    let resolved = GitHubCommandCheckoutResolver.resolve(
        repository: "NousResearch/hermes-agent",
        headSHA: nil,
        dataRoot: root,
        searchRoots: [searchRoot]
    )
    #expect(resolved?.standardizedFileURL == real.standardizedFileURL)

    // A repository that exists nowhere locally resolves to nil rather than
    // guessing a directory.
    let missing = GitHubCommandCheckoutResolver.resolve(
        repository: "NousResearch/not-cloned-here",
        headSHA: nil,
        dataRoot: root,
        searchRoots: [searchRoot]
    )
    #expect(missing == nil)

    // End to end through the tool: chat names the repo and gets the profile.
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )
    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("unknown repository"),
            "message_id": .string("repo-unknown"),
            "repository": .string("NousResearch/not-cloned-here"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    // Unresolvable repository degrades to today's behavior: message still
    // sends, but with no directory and no elevated profile.
    #expect(inputs[0]["workingDirectory"] == nil)
    #expect(inputs[0]["executionProfile"] == nil)
}

/// The positive half of the wiring: a repository that DOES resolve must reach
/// the wakeup with both the verified directory and the elevated execution
/// profile, from an ordinary chat surface. This drives the resolver's real
/// defaultSearchRoots (dataRoot is <base>/NativeAgent/data, so <base> is a
/// search root) rather than injecting searchRoots the tool path cannot pass.
///
/// The fixture repository name is deliberately one that cannot exist on a real
/// machine: defaultSearchRoots also scans the real home (~/Projects, ~/.hermes,
/// ~/Developer), so a common name like NousResearch/hermes-agent would resolve
/// against the developer's actual clone and make this test machine-dependent.
@Test
func swiftToolDispatcher_codexMessageRepositoryGrantsProfileFromChat() async throws {
    let base = try makeTempRoot("codex-message-repository-hit")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let checkout = base.appendingPathComponent("nativeagent-repo-optin-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: checkout)
    try runRepositoryTestGit(
        ["remote", "add", "origin", "https://github.com/nativeagent-tests/nativeagent-repo-optin-fixture.git"],
        at: checkout
    )

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("rebase and push"),
            "message_id": .string("repo-hit"),
            "repository": .string("nativeagent-tests/nativeagent-repo-optin-fixture"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    #expect(inputs[0]["workingDirectory"] == .string(checkout.standardizedFileURL.path))
    #expect(inputs[0]["executionProfile"] == .string("github-command-repository-network-v1"))
}

/// Slug extraction from request prose. Pure string work -- the resolver still
/// decides whether any candidate is a real checkout.
@Test
func swiftToolDispatcher_repositorySlugCandidatesFromRequestText() {
    // A GitHub URL is the strongest signal and wins outright.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "Please rebase https://github.com/NousResearch/hermes-agent/pull/64288 onto main"
    ) == ["NousResearch/hermes-agent"])

    // The real SSH form uses a colon, not a slash.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "clone git@github.com:acme/widget.git"
    ) == ["acme/widget"])
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "clone https://github.com/acme/widget.git"
    ) == ["acme/widget"])

    // A bare slug is accepted only when no URL named a repository.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "sync NousResearch/hermes-agent for me"
    ) == ["NousResearch/hermes-agent"])

    // URL beats the bare token when both appear.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "see github.com/acme/widget, not other/thing"
    ) == ["acme/widget"])

    // Path-shaped and malformed tokens never become candidates.
    let noise = SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "check /etc/passwd and ~/Projects/secret and owner/../../etc and a/b/c and just-a-word"
    )
    #expect(noise.isEmpty)

    // Ambiguity is preserved for the resolver to reject, not silently collapsed.
    let two = SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "compare github.com/acme/widget with github.com/acme/gadget"
    )
    #expect(two == ["acme/widget", "acme/gadget"])

    // The resolver's work stays bounded no matter how slug-shaped the prose is.
    let many = (1...20).map { "owner\($0)/name\($0)" }.joined(separator: " ")
    #expect(SwiftToolDispatcher.repositorySlugCandidates(inRequestText: many).count == 8)
}

/// The 2026-08-05 regression: Agent omitted `repository`, so the send carried no
/// execution profile, Codex had no GitHub network path, and the turn ground to a
/// silent harness kill. The profile must now attach from the request text alone.
@Test
func swiftToolDispatcher_codexMessageInfersRepositoryFromRequestText() async throws {
    let base = try makeTempRoot("codex-message-repository-inferred")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let checkout = base.appendingPathComponent("nativeagent-inferred-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: checkout)
    try runRepositoryTestGit(
        ["remote", "add", "origin", "https://github.com/nativeagent-tests/nativeagent-inferred-fixture.git"],
        at: checkout
    )

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    // No `repository`, no `working_directory` -- only prose naming the repo.
    let response = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Rebase https://github.com/nativeagent-tests/nativeagent-inferred-fixture/pull/64288 onto main and push."),
            "message_id": .string("repo-inferred"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    #expect(inputs[0]["workingDirectory"] == .string(checkout.standardizedFileURL.path))
    #expect(inputs[0]["executionProfile"] == .string("github-command-repository-network-v1"))
    // The auto-attach is observable at the call site, not silent.
    if case .object(let object) = response {
        #expect(object["executionProfile"] == .string("github-command-repository-network-v1"))
        #expect(object["repositorySource"] == .string("inferred_from_request"))
    } else {
        Issue.record("codex_message returned a non-object response")
    }
}

/// Prose naming NO resolvable repository must degrade to today's behavior rather
/// than handing Codex a network-enabled checkout of something adjacent.
@Test
func swiftToolDispatcher_codexMessageInferenceDegradesWhenNothingResolves() async throws {
    let base = try makeTempRoot("codex-message-repository-inferred-miss")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Look at github.com/nativeagent-tests/never-cloned-anywhere please."),
            "message_id": .string("repo-inferred-miss"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    #expect(inputs[0]["workingDirectory"] == nil)
    #expect(inputs[0]["executionProfile"] == nil)
}

/// A model must not be able to smuggle path syntax through `repository`.
@Test
func swiftToolDispatcher_repositorySlugRejectsPathShapedInput() {
    #expect(SwiftToolDispatcher.isWellFormedRepositorySlug("NousResearch/hermes-agent"))
    #expect(SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name.with.dots"))

    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("/etc"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("~/Projects/secret"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/../../etc"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name/extra"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug(""))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/na me"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name;rm -rf /"))
}

@Test
func swiftToolDispatcher_codexExecArguments_matchCurrentCli() async throws {
    let args = SwiftToolDispatcher.codexExecArguments(
        sandbox: "read-only",
        cwd: "/tmp/nativeagent",
        lastMessagePath: "/tmp/nativeagent/last-message.txt",
        model: "gpt-test",
        reasoningEffort: "xhigh",
        serviceTier: "priority",
        prompt: "return OK"
    )

    #expect(Array(args.prefix(3)) == ["codex", "exec", "--ephemeral"])
    #expect(!args.contains("--ask-for-approval"))
    #expect(args.contains("--sandbox"))
    #expect(args.contains("read-only"))
    #expect(args.contains("-C"))
    #expect(args.contains("/tmp/nativeagent"))
    #expect(args.contains("-o"))
    #expect(args.contains("/tmp/nativeagent/last-message.txt"))
    #expect(args.contains("-m"))
    #expect(args.contains("gpt-test"))
    #expect(args.contains("model_reasoning_effort=\"xhigh\""))
    #expect(args.contains("service_tier=\"priority\""))
    #expect(args.last == "return OK")
}

@Test
func swiftToolDispatcher_codexBrainControlsValidateModelCapabilities() {
    let terra = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-5.6-terra"),
        "reasoning_effort": .string("extra high"),
        "fast": .bool(true),
    ])
    #expect(terra == .success(.init(
        model: "gpt-5.6-terra",
        reasoningEffort: "xhigh",
        serviceTier: "priority",
        fast: true
    )))

    let lunaUltra = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-5.6-luna"),
        "reasoning_effort": .string("ultra"),
    ])
    guard case .failure(.invalidReasoningEffort(_, let model, let supported)) = lunaUltra else {
        Issue.record("Luna Ultra should fail before spawning Codex")
        return
    }
    #expect(model == "gpt-5.6-luna")
    #expect(supported.contains("max"))
    #expect(!supported.contains("ultra"))
}

@Test
func swiftToolDispatcher_invokeCodexDangerFullAccessRequiresDeveloperModePolicy() {
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [:]) == false)
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [
        "developerMode": .bool(false),
    ]) == false)
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [
        "developerMode": .bool(true),
    ]) == true)
}

@Test
func swiftToolDispatcher_personaAppendSection_writesGrowthOnTelegramSurface() async throws {
    let root = try makeTempRoot("persona-growth")
    defer { try? FileManager.default.removeItem(at: root) }
    let personaRoot = root
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("Agent", isDirectory: true)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try "# Soul".write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    try "# Growth\n\nSeed".write(to: personaRoot.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let result = try await tools.dispatch(
        tool: "persona_append_section",
        input: [
            "kind": .string("growth"),
            "title": .string("Telegram calibration"),
            "content": .string("Telegram can add to Agent's growth journal."),
        ],
        surface: "telegram"
    )

    guard case .object(let obj) = result else {
        Issue.record("expected persona_append_section result object")
        return
    }
    #expect(obj["ok"] == .bool(true))
    #expect(obj["kind"] == .string("growth"))
    guard case .string(let rawPath)? = obj["path"] else {
        Issue.record("expected path string")
        return
    }
    #expect(
        URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        == personaRoot.appendingPathComponent("GROWTH.md").resolvingSymlinksInPath().path
    )
    guard case .int(let bytes)? = obj["bytes_appended"] else {
        Issue.record("expected bytes_appended")
        return
    }
    #expect(bytes > 0)

    let body = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body.contains("## Telegram calibration"))
    #expect(body.contains("Telegram can add to Agent's growth journal."))

    let readBack = try await tools.dispatch(
        tool: "persona_read",
        input: ["kind": .string("growth")],
        surface: "telegram"
    )
    guard case .object(let readObj) = readBack else {
        Issue.record("expected persona_read object")
        return
    }
    #expect(readObj["ok"] == .bool(true))
    if case .string(let content)? = readObj["content"] {
        #expect(content.contains("## Telegram calibration"))
    } else {
        Issue.record("expected persona_read content")
    }
}

@Test
func swiftToolDispatcher_list_tools_aliases_tool_catalog() async throws {
    let root = try makeTempRoot("list-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let alias = try await tools.dispatch(tool: "list_tools", input: [:], surface: "telegram")
    guard case .object(let obj) = alias else {
        Issue.record("expected list_tools object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["runtime"] == .string("swift-native"))
    guard case .array(let names)? = obj["available_tools"] else {
        Issue.record("expected available_tools")
        return
    }
    #expect(names.contains(.string("tool_catalog")))
    #expect(names.contains(.string("list_tools")))
    #expect(names.contains(.string("tool_load")))
    #expect(names.contains(.string("context_lookup")))
    #expect(names.contains(.string("scratchpad_read")))
    #expect(names.contains(.string("recent_trace_summary")))
    #expect(names.contains(.string("search_chat_history")))
    #expect(names.contains(.string("session_search")))
}

@Test
func swiftToolDispatcher_search_chat_history_finds_ranked_session_snippets() async throws {
    let root = try makeTempRoot("search-chat-history")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeChatSessionsJSON(root, sessions: [
        ["id": "alpha", "title": "Coffee lead", "createdAt": "2026-06-01T10:00:00Z"],
        ["id": "beta", "title": "Memory work", "createdAt": "2026-06-02T10:00:00Z"],
    ])
    try writeMessagesJSONL(root, sessionId: "alpha", lines: [
        try chatMessageLine(role: "user", content: "We should check Verve Coffee Roasters again.", createdAt: "2026-06-01T10:00:01Z"),
        try chatMessageLine(role: "assistant", content: "I will search the market notes.", createdAt: "2026-06-01T10:00:02Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "beta", lines: [
        try chatMessageLine(role: "user", content: "Make recall natural and add session search.", createdAt: "2026-06-02T10:00:01Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "search_chat_history",
        input: ["query": .string("Verve Coffee")],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let hits)? = obj["hits"],
          case .object(let first)? = hits.first else {
        Issue.record("expected chat history search hits")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["source"] == .string("chat_history_jsonl"))
    #expect(first["session_id"] == .string("alpha"))
    #expect(first["session_title"] == .string("Coffee lead"))
    #expect(first["role"] == .string("user"))
    guard case .string(let preview)? = first["preview"] else {
        Issue.record("expected preview")
        return
    }
    #expect(preview.contains("Verve Coffee Roasters"))
}

@Test
func swiftToolDispatcher_search_chat_history_defaults_current_session_first() async throws {
    let root = try makeTempRoot("search-current-first")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMessagesJSONL(root, sessionId: "current", lines: [
        try chatMessageLine(role: "user", content: "The silver compass belongs in this active chat.", createdAt: "2026-06-01T10:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "older", lines: [
        try chatMessageLine(role: "user", content: "The silver compass appears in an older chat too.", createdAt: "2026-06-02T10:00:01Z"),
        try chatMessageLine(role: "assistant", content: "The orchard note is only in the older chat.", createdAt: "2026-06-02T10:00:02Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let currentFirst = try await tools.dispatch(
        tool: "search_chat_history",
        input: [
            "query": .string("silver compass"),
            "current_session_id": .string("current"),
        ],
        surface: "chat"
    )
    guard case .object(let currentObj) = currentFirst,
          case .array(let currentHits)? = currentObj["hits"],
          case .object(let firstCurrent)? = currentHits.first else {
        Issue.record("expected current-session-first hits")
        return
    }
    #expect(currentObj["scope"] == .string("auto"))
    #expect(currentObj["phase"] == .string("current_session"))
    #expect(currentObj["fallback_skipped"] == .string("all_sessions"))
    #expect(currentObj["searched_session_count"] == .int(1))
    #expect(firstCurrent["session_id"] == .string("current"))

    let broad = try await tools.dispatch(
        tool: "search_chat_history",
        input: [
            "query": .string("orchard"),
            "current_session_id": .string("current"),
            "scope": .string("all_sessions"),
        ],
        surface: "chat"
    )
    guard case .object(let broadObj) = broad,
          case .array(let broadHits)? = broadObj["hits"],
          case .object(let firstBroad)? = broadHits.first else {
        Issue.record("expected all-session hits")
        return
    }
    #expect(broadObj["phase"] == .string("all_sessions"))
    #expect(firstBroad["session_id"] == .string("older"))
}

@Test
func swiftToolDispatcher_session_search_alias_can_scope_to_one_session() async throws {
    let root = try makeTempRoot("session-search-alias")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMessagesJSONL(root, sessionId: "alpha", lines: [
        try chatMessageLine(role: "user", content: "Find honk shoo in this session.", createdAt: "2026-06-01T10:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "beta", lines: [
        try chatMessageLine(role: "user", content: "Another honk shoo mention that should be out of scope.", createdAt: "2026-06-02T10:00:01Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let load = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string("alpha"),
            "names": .array([.string("session_search")]),
        ],
        surface: "telegram"
    )
    guard case .object(let loadObj) = load else {
        Issue.record("expected session_search load result")
        return
    }
    #expect(loadObj["loaded"] == .array([.string("session_search")]))

    let result = try await tools.dispatch(
        tool: "session_search",
        input: [
            "query": .string("honk shoo"),
            "session_id": .string("alpha"),
        ],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let hits)? = obj["hits"],
          case .object(let first)? = hits.first else {
        Issue.record("expected scoped session_search hit")
        return
    }
    #expect(obj["tool"] == .string("session_search"))
    #expect(obj["searched_session_count"] == .int(1))
    #expect(first["session_id"] == .string("alpha"))
}

@Test
func swiftToolDispatcher_context_lookup_uses_swift_context_module() async throws {
    let root = try makeTempRoot("context-lookup")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "context_lookup",
        input: ["query": .string("memory")],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected context_lookup object")
        return
    }
    #expect(obj["status"] == .string("ready"))
    #expect(obj["type"] == .string("lookup_feature_surface"))
    guard case .array(let features)? = obj["features"] else {
        Issue.record("expected feature-surface records")
        return
    }
    #expect(!features.isEmpty)
}

@Test
func swiftToolDispatcher_scratchpad_read_reads_session_scratch_json() async throws {
    let root = try makeTempRoot("scratchpad-read")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "telegram:12345"
    let scratchPath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
        .appendingPathComponent("scratch.json")
    try FileManager.default.createDirectory(
        at: scratchPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONValue.object([
        "plan": .string("ship swift"),
        "count": .int(2),
    ]).serializedData(pretty: true).write(to: scratchPath)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let all = try await tools.dispatch(
        tool: "scratchpad_read",
        input: ["session_id": .string(sessionID)],
        surface: "telegram"
    )
    guard case .object(let allObj) = all,
          case .array(let keys)? = allObj["keys"],
          case .object(let entries)? = allObj["entries"] else {
        Issue.record("expected scratchpad_read entries")
        return
    }
    #expect(allObj["found"] == .bool(true))
    #expect(keys.contains(.string("plan")))
    #expect(entries["plan"] == .string("ship swift"))

    let one = try await tools.dispatch(
        tool: "scratchpad_read",
        input: [
            "session_id": .string(sessionID),
            "key": .string("plan"),
        ],
        surface: "telegram"
    )
    guard case .object(let oneObj) = one else {
        Issue.record("expected keyed scratchpad_read object")
        return
    }
    #expect(oneObj["found"] == .bool(true))
    #expect(oneObj["value"] == .string("ship swift"))
}

@Test
func swiftToolDispatcher_recent_trace_summary_omits_raw_payload_values() async throws {
    let root = try makeTempRoot("recent-traces")
    defer { try? FileManager.default.removeItem(at: root) }
    let lane = TurnTracePersistLane(dataRootOverride: root)
    await lane.append(TurnTraceEvent(
        turnId: "t1",
        kind: "research.run",
        payload: .object([
            "status": .string("completed"),
            "secret": .string("RAW_SECRET_NEVER_RETURN"),
            "sourceCount": .int(2),
        ])
    ))
    await lane.append(TurnTraceEvent(
        turnId: "t2",
        kind: "dream.rem",
        payload: .object([
            "status": .string("completed"),
            "body": .string("RAW_DREAM_BODY_NEVER_RETURN"),
        ])
    ))

    let tools = SwiftToolDispatcher(dataRoot: root)
    let result = try await tools.dispatch(
        tool: "recent_trace_summary",
        input: ["kind": .string("research"), "limit": .int(10)],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let traces)? = obj["traces"],
          case .object(let trace)? = traces.first,
          case .array(let payloadKeys)? = trace["payload_keys"] else {
        Issue.record("expected trace summary")
        return
    }
    #expect(obj["count"] == .int(1))
    #expect(trace["turn_id"] == .string("t1"))
    #expect(payloadKeys.contains(.string("secret")))
    let rendered = String(data: try result.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!rendered.contains("RAW_SECRET_NEVER_RETURN"))
    #expect(!rendered.contains("RAW_DREAM_BODY_NEVER_RETURN"))
}

@Test
func swiftToolDispatcher_recent_trace_summary_schema_supports_session_aliases() async throws {
    let root = try makeTempRoot("recent-traces-schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
    let schema = try #require(schemas.first { $0.name == "recent_trace_summary" })
    let parsed = try JSONValue.parse(schema.parametersJSON)
    guard case .object(let object) = parsed,
          case .object(let properties)? = object["properties"] else {
        Issue.record("expected recent_trace_summary object schema")
        return
    }
    #expect(properties["session_id"] != nil)
    #expect(properties["sessionId"] != nil)
}

@Test
func swiftToolDispatcher_builderMessageSchemasExposeConversationReplies() async throws {
    let root = try makeTempRoot("builder-conversation-schemas")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
    for toolName in ["codex_message", "claude_message", "omp_message"] {
        let schema = try #require(schemas.first { $0.name == toolName })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let object) = parsed,
              case .object(let properties)? = object["properties"] else {
            Issue.record("expected \(toolName) object schema")
            continue
        }
        #expect(properties["conversation_id"] != nil)
        #expect(schema.description.contains("conversationId"))
    }
}

@Test
func swiftToolDispatcher_tool_load_reports_context_trace_scratch_tools() async throws {
    let root = try makeTempRoot("tool-load-context")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("context")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected context tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("context_lookup")))
    #expect(loaded.contains(.string("scratchpad_read")))
    #expect(loaded.contains(.string("recent_trace_summary")))
}

@Test
func swiftToolDispatcher_tool_load_reports_memory_and_session_search_tools() async throws {
    let root = try makeTempRoot("tool-load-memory")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("memory")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected memory tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("recall_memory")))
    #expect(loaded.contains(.string("recall_search")))
    #expect(loaded.contains(.string("search_kg")))
    #expect(loaded.contains(.string("search_chat_history")))
    #expect(loaded.contains(.string("session_search")))
}

@Test
func swiftToolDispatcher_tool_load_categoryWithSession_persistsTools() async throws {
    let root = try makeTempRoot("tool-load-category-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "test-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("markets"),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"],
          case .array(let schemasAdded)? = obj["schemas_added"] else {
        Issue.record("expected persisted category load object")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loaded.contains(.string("market_status")))
    #expect(schemasAdded.contains { row in
        guard case .object(let rowObj) = row else { return false }
        return rowObj["name"] == .string("market_status") && rowObj["parameters"] != nil
    })

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(state.activeTools.contains("market_status"))
    let schemas = try await tools.listAvailableToolSchemas(activeTools: state.activeTools)
    #expect(schemas.contains { $0.name == "market_status" })
}

@Test
func swiftToolDispatcher_turnActiveToolsAllowsLazyDispatchWithoutPersisting() async throws {
    let root = try makeTempRoot("turn-active-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "turn-active-\(UUID().uuidString)"

    let blocked = try await tools.dispatch(
        tool: "market_status",
        input: ["__session_id": .string(sessionId)],
        surface: "chat"
    )
    guard case .object(let blockedObj) = blocked else {
        Issue.record("expected not_loaded object")
        return
    }
    #expect(blockedObj["reason"] == .string("not_loaded"))

    let allowed = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "market_status",
            input: ["__session_id": .string(sessionId)],
            surface: "chat"
        )
    }
    guard case .object(let allowedObj) = allowed else {
        Issue.record("expected market_status object")
        return
    }
    #expect(allowedObj["runtime"] == .string("swift-native"))
    #expect(allowedObj["reason"] == nil)

    // 2026-07-21 audit: assert against the temp-root store the dispatcher
    // under test owns; ActiveToolsStore.shared.load sweeps the LIVE dir.
    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_toolLoadSkipsPersistingTurnActiveTools() async throws {
    let root = try makeTempRoot("tool-load-turn-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "tool-load-turn-active-\(UUID().uuidString)"

    let result = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "tool_load",
            input: [
                "session_id": .string(sessionId),
                "names": .array([.string("market_status")]),
            ],
            surface: "chat"
        )
    }
    guard case .object(let obj) = result,
          case .array(let loadedNow)? = obj["loaded_now"],
          case .array(let alreadyActive)? = obj["already_active"],
          case .array(let turnActive)? = obj["turn_active"] else {
        Issue.record("expected tool_load object with active arrays")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loadedNow.isEmpty)
    #expect(alreadyActive.contains(.string("market_status")))
    #expect(turnActive.contains(.string("market_status")))
    #expect(obj["session_active_count"] == .int(0))

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_toolCatalogReportsTurnActiveToolsWithoutPersisting() async throws {
    let root = try makeTempRoot("tool-catalog-turn-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "tool-catalog-turn-active-\(UUID().uuidString)"

    let result = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "tool_catalog",
            input: ["session_id": .string(sessionId)],
            surface: "chat"
        )
    }
    guard case .object(let obj) = result,
          case .array(let currentlyLoaded)? = obj["currently_loaded"],
          case .array(let discoveryOnly)? = obj["discovery_only_tools"],
          case .array(let turnActive)? = obj["turn_active_tools"] else {
        Issue.record("expected tool_catalog active arrays")
        return
    }
    #expect(currentlyLoaded.contains(.string("market_status")))
    #expect(!discoveryOnly.contains(.string("market_status")))
    #expect(turnActive.contains(.string("market_status")))

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_tool_load_reports_builder_gap_truthfully() async throws {
    let root = try makeTempRoot("tool-load-builder")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("builder")],
        surface: "telegram"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected tool_load object")
        return
    }
    #expect(obj["status"] == .string("partial"))
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["builder_mode"] == .string("policy_locked"))
    #expect(obj["full_mac_active"] == .bool(false))
    guard case .array(let loaded)? = obj["loaded"],
          case .array(let unavailable)? = obj["unavailable"],
          case .array(let activeTools)? = obj["active_tools"] else {
        Issue.record("expected loaded, unavailable, and active_tools arrays")
        return
    }
    #expect(unavailable.contains(.string("shell")))
    #expect(unavailable.contains(.string("git")))
    #expect(!unavailable.contains(.string("write_file")))
    #expect(loaded.contains(.string("write_file")))
    #expect(!activeTools.contains(.string("list_tools")))
    #expect(activeTools.contains(.string("tool_catalog")))
    #expect(activeTools.contains(.string("tool_load")))
    #expect(activeTools.contains(.string("write_file")))
}

@Test
func swiftToolDispatcher_trustedWorkspaceRootsExposeAllObsidianVaults() async throws {
    let repo = try makeTempRoot("trusted-obsidian-root")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let obsidianRoot = repo.appendingPathComponent("Obsidian Documents", isDirectory: true)
    let codexVault = obsidianRoot.appendingPathComponent("Codex", isDirectory: true)
    let claudeVault = obsidianRoot.appendingPathComponent("Claude code", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexVault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeVault, withIntermediateDirectories: true)
    try "codex start".write(
        to: codexVault.appendingPathComponent("00 Start Here.md"),
        atomically: true,
        encoding: .utf8
    )
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("balanced"),
        "filePolicy": .object([
            "workspaceRoots": .array([.string(obsidianRoot.path)]),
            "outsideWorkspaceDefault": .string("deny"),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("write_file"))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "telegram")
    guard case .object(let catalogObj) = catalog,
          case .array(let trustedRoots)? = catalogObj["trusted_workspace_roots"] else {
        Issue.record("expected trusted_workspace_roots in tool catalog")
        return
    }
    #expect(trustedRoots.contains(.string(obsidianRoot.path)))
    let canonicalWorkspace = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
    #expect(trustedRoots.contains(.string(canonicalWorkspace.path)))

    _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
    let workspaceWrite = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string("workspace/demo.txt"),
            "content": .string("canonical workspace"),
        ],
        surface: "telegram"
    )
    guard case .object(let workspaceWriteObject) = workspaceWrite else {
        Issue.record("expected canonical workspace write receipt")
        return
    }
    #expect(workspaceWriteObject["ok"] == .bool(true))
    #expect(try String(
        contentsOf: canonicalWorkspace.appendingPathComponent("demo.txt"),
        encoding: .utf8
    ) == "canonical workspace")

    let list = try await tools.dispatch(
        tool: "list_dir",
        input: ["path": .string(obsidianRoot.path)],
        surface: "telegram"
    )
    guard case .array(let vaults) = list else {
        Issue.record("expected vault list")
        return
    }
    #expect(vaults.contains(.string("Codex")))
    #expect(vaults.contains(.string("Claude code")))

    let read = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string(codexVault.appendingPathComponent("00 Start Here.md").path)],
        surface: "telegram"
    )
    #expect(read == .string("codex start"))

    let target = claudeVault.appendingPathComponent("handoff.md")
    let writeResult = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("shared note"),
        ],
        surface: "telegram"
    )
    guard case .object(let writeObj) = writeResult else {
        Issue.record("expected write_file object")
        return
    }
    #expect(writeObj["ok"] == .bool(true))
    #expect((try? String(contentsOf: target, encoding: .utf8)) == "shared note")
}

@Test
func swiftToolDispatcher_trustedWorkspaceWriteRejectsOutsideRootWithoutFullMac() async throws {
    let repo = try makeTempRoot("trusted-obsidian-reject")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let obsidianRoot = repo.appendingPathComponent("Obsidian Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: obsidianRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("balanced"),
        "filePolicy": .object([
            "workspaceRoots": .array([.string(obsidianRoot.path)]),
            "outsideWorkspaceDefault": .string("deny"),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let target = repo.appendingPathComponent("outside.md")
    do {
        _ = try await tools.dispatch(
            tool: "write_file",
            input: [
                "path": .string(target.path),
                "content": .string("blocked"),
            ],
            surface: "telegram"
        )
        Issue.record("expected write_file outside trusted workspace root to be blocked")
    } catch AutonomyGateError.toolDenied(let reason) {
        #expect(reason.contains("outside trusted workspace roots"))
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test
func swiftToolDispatcher_market_status_sanitizes_configured_sources() async throws {
    let root = try makeTempRoot("market-status")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMarketSecrets(root)
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(tool: "market_status", input: [:], surface: "chat")
    guard case .object(let obj) = result else {
        Issue.record("expected market_status object")
        return
    }
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["markets_configured"] == .bool(true))
    #expect(obj["tradingview_configured"] == .bool(true))
    guard case .array(let sources)? = obj["sources"],
          case .array(let watchlists)? = obj["watchlists"],
          case .object(let tv)? = obj["tradingview"] else {
        Issue.record("expected sources/watchlists/tradingview")
        return
    }
    #expect(sources.contains { item in
        guard case .object(let row) = item else { return false }
        return row["id"] == .string("finnhub")
            && row["enabled"] == .bool(true)
            && row["has_secret"] == .bool(true)
    })
    #expect(watchlists.contains { item in
        guard case .object(let row) = item else { return false }
        return row["id"] == .string("crypto") && row["symbol_count"] == .int(2)
    })
    #expect(tv["plan"] == .string("pro"))
    #expect(tv["has_session_cookie"] == .bool(true))
    #expect(tv["has_auth_token"] == .bool(true))

    let rendered = String(data: try result.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!rendered.contains("FINNHUB_TEST_KEY_NEVER_RETURN"))
    #expect(!rendered.contains("TV_SESSION_NEVER_RETURN"))
    #expect(!rendered.contains("TV_AUTH_TOKEN_NEVER_RETURN"))
}

@Test
func swiftToolDispatcher_market_watchlists_reads_local_groups() async throws {
    let root = try makeTempRoot("market-watchlists")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMarketSecrets(root)
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "market_watchlists",
        input: ["group": .string("crypto")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let watchlists)? = obj["watchlists"],
          case .object(let row)? = watchlists.first,
          case .array(let symbols)? = row["symbols"] else {
        Issue.record("expected crypto watchlist row")
        return
    }
    #expect(obj["source"] == .string("local"))
    #expect(row["id"] == .string("crypto"))
    #expect(symbols == [.string("BTC-USD"), .string("ETH-USD")])
}

@Test
func swiftToolDispatcher_tool_load_reports_market_tools() async throws {
    let root = try makeTempRoot("tool-load-market")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("markets")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected market tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("market_status")))
    #expect(loaded.contains(.string("market_watchlists")))
    #expect(loaded.contains(.string("tradingview_watchlist")))
    #expect(loaded.contains(.string("market_quote")))
}

@Test
func swiftToolDispatcher_tool_load_reports_agentmail_tools() async throws {
    let root = try makeTempRoot("tool-load-agentmail")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "agentmail-\(UUID().uuidString)"

    let catalog = try await tools.dispatch(
        tool: "tool_catalog",
        input: ["session_id": .string(sessionId)],
        surface: "chat"
    )
    guard case .object(let catalogObj) = catalog,
          case .array(let discoveryOnly)? = catalogObj["discovery_only_tools"],
          case .array(let currentlyLoaded)? = catalogObj["currently_loaded"] else {
        Issue.record("expected catalog arrays")
        return
    }
    #expect(discoveryOnly.contains(.string("agentmail_list")))
    #expect(discoveryOnly.contains(.string("agentmail_read")))
    #expect(discoveryOnly.contains(.string("agentmail_send")))
    #expect(!currentlyLoaded.contains(.string("agentmail_list")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("agentmail_list"))

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("agentmail"),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"],
          case .array(let schemasAdded)? = obj["schemas_added"] else {
        Issue.record("expected agentmail tool_load object")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loaded.contains(.string("agentmail_list")))
    #expect(loaded.contains(.string("agentmail_read")))
    #expect(loaded.contains(.string("agentmail_send")))
    #expect(schemasAdded.contains { row in
        guard case .object(let rowObj) = row else { return false }
        return rowObj["name"] == .string("agentmail_send") && rowObj["parameters"] != nil
    })
}

@Test
func swiftToolDispatcher_tool_load_reports_slack_tools() async throws {
    let root = try makeTempRoot("tool-load-slack")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("slack")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected slack tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("slack_status")))
    #expect(loaded.contains(.string("slack_list_channels")))
    #expect(loaded.contains(.string("slack_search_messages")))
    #expect(loaded.contains(.string("slack_post_message")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("slack_post_message"))
}

@Test
func swiftToolDispatcher_tool_load_reports_github_tools() async throws {
    let root = try makeTempRoot("tool-load-github")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("github")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected github tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("github_status")))
    #expect(loaded.contains(.string("github_list_repos")))
    #expect(loaded.contains(.string("github_list_issues")))
    #expect(loaded.contains(.string("github_search")))
    #expect(loaded.contains(.string("github_list_pull_requests")))
    #expect(loaded.contains(.string("github_get_issue")))
    #expect(loaded.contains(.string("github_get_pull_request")))
    #expect(loaded.contains(.string("github_pull_request_files")))
    #expect(loaded.contains(.string("github_pull_request_activity")))
    #expect(loaded.contains(.string("github_discover_tracking")))
    #expect(loaded.contains(.string("github_project_digest")))
    #expect(loaded.contains(.string("github_mutate")))
    #expect(loaded.contains(.string("github_set_repo_visibility")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("github_list_repos"))
}

@Test
func swiftToolDispatcher_agentmailSendStagingFailsWhenUnconfigured() async throws {
    let root = try makeTempRoot("agentmail-send-direct")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Direct test"),
            "body": .string("This should attempt Agent's AgentMail send path."),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected AgentMail send result")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["actionId"] == .string("agentmail.send"))
    #expect(obj["error"] == .string("agentmail_not_configured"))

    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}

@Test
func autonomyGate_agentmailSendStagingWithApprovalPolicy() async throws {
    let root = try makeTempRoot("agentmail-send-gated-direct")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicy(root, .object([
        "toolAutonomy": .object([
            "agentmail.send": .string("send_approval"),
            "agentmail_send": .string("send_approval"),
        ]),
    ]))
    let tools = SwiftToolDispatcher(dataRoot: root)
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))
    let gated = AutonomyGatedDispatcher(
        inner: tools,
        gate: gate,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root)
    )

    let result = try await gated.dispatch(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Gated approval test"),
            "body": .string("This should stage through the autonomy wrapper."),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected AgentMail approval staging result")
        return
    }

    #expect(obj["status"] == .string("failed"))
    #expect(obj["actionId"] == .string("agentmail.send"))
    #expect(obj["error"] == .string("agentmail_not_configured"))
    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}

@Test
func swiftToolDispatcher_fullMacTrust_exposes_builder_and_mac_app_tools() async throws {
    let repo = try makeTempRoot("full-mac-builder")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(true),
            "shell_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("write_file"))
    #expect(names.contains("grep"))
    #expect(names.contains("git_status"))
    #expect(names.contains("repo_dirty_summary"))
    #expect(names.contains("system_info"))
    #expect(names.contains("restart_app"))
    #expect(names.contains("install_app"))
    #expect(names.contains("mac_focus_app"))
    #expect(names.contains("mac_quit_app"))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "telegram")
    guard case .object(let catalogObj) = catalog else {
        Issue.record("expected catalog object")
        return
    }
    #expect(catalogObj["builder_mode"] == .string("available"))
    #expect(catalogObj["full_mac_active"] == .bool(true))
    #expect(catalogObj["app_control_allowed"] == .bool(true))
    if case .array(let builderTools)? = catalogObj["builder_available_tools"] {
        #expect(builderTools.contains(.string("restart_app")))
        #expect(builderTools.contains(.string("install_app")))
    } else {
        Issue.record("expected builder_available_tools array")
    }
    if case .array(let appTools)? = catalogObj["mac_app_available_tools"] {
        #expect(appTools.contains(.string("mac_focus_app")))
        #expect(appTools.contains(.string("mac_quit_app")))
    } else {
        Issue.record("expected mac_app_available_tools array")
    }

    let target = repo
        .appendingPathComponent("outside-workspace", isDirectory: true)
        .appendingPathComponent("note.txt")
    let writeResult = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("full mac swift write"),
        ],
        surface: "telegram"
    )
    guard case .object(let writeObj) = writeResult else {
        Issue.record("expected write_file object")
        return
    }
    #expect(writeObj["ok"] == .bool(true))
    #expect((try? String(contentsOf: target, encoding: .utf8)) == "full mac swift write")

    let readResult = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string(target.path)],
        surface: "telegram"
    )
    #expect(readResult == .string("full mac swift write"))

    let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
    let gate = AutonomyGate(trust: trust)
    #expect(try await gate.autonomyLevel(toolName: "write_file", surface: "telegram", originTrusted: true) == "auto")
    #expect(try await gate.autonomyLevel(toolName: "git_status", surface: "telegram", originTrusted: true) == "auto")
    #expect(try await gate.autonomyLevel(toolName: "mac_focus_app", surface: "telegram", originTrusted: true) == "auto")
    for surface in ["chat", "telegram", "ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
        #expect(try await gate.autonomyLevel(toolName: "install_app", surface: surface, originTrusted: true) == "auto")
        #expect(try await gate.autonomyLevel(toolName: "restart_app", surface: surface, originTrusted: true) == "auto")
    }
}

@Test
func swiftToolDispatcher_iOSFullMacRequiresRemoteIOSPolicy() async throws {
    let repo = try makeTempRoot("full-mac-ios-remote")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(false),
            "approval_required_for": .array([]),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let target = repo
        .appendingPathComponent("outside-workspace", isDirectory: true)
        .appendingPathComponent("ios-remote-note.txt")

    do {
        _ = try await tools.dispatch(
            tool: "write_file",
            input: [
                "path": .string(target.path),
                "content": .string("should not write"),
            ],
            surface: "ios"
        )
        Issue.record("expected iOS Full Mac write_file to respect remote_from_ios_allowed=false")
    } catch AutonomyGateError.toolDenied(let reason) {
        #expect(reason.contains("outside trusted workspace roots"))
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "ios")
    guard case .object(let catalogObj) = catalog else {
        Issue.record("expected catalog object")
        return
    }
    #expect(catalogObj["full_mac_active"] == .bool(true))
    #expect(catalogObj["file_ops_allowed"] == .bool(false))
    #expect(catalogObj["builder_mode"] == .string("policy_locked"))

    let localWrite = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("local write allowed"),
        ],
        surface: "chat"
    )
    guard case .object(let localObj) = localWrite else {
        Issue.record("expected local write_file object")
        return
    }
    #expect(localObj["ok"] == .bool(true))

    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: dataRoot))
    let remoteDecision = try await gate.decide(toolName: "write_file", surface: "ios")
    if case .allow = remoteDecision {
        Issue.record("expected iOS autonomy gate not to auto-allow Full Mac when remote_from_ios_allowed=false")
    }
    #expect(try await gate.decide(toolName: "write_file", surface: "chat") == .allow)
}

@Test
func swiftToolDispatcher_lists_and_reads_persona_skill_bodies() async throws {
    let repo = try makeTempRoot("skills-repo")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let bodyDir = repo
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("bodies", isDirectory: true)
    let dataSkillBodyDir = dataRoot
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("bodies", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bodyDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataSkillBodyDir, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: repo.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("script", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "#!/usr/bin/env bash\n".write(
        to: repo.appendingPathComponent("script/init_persona.sh"),
        atomically: true,
        encoding: .utf8
    )
    try "# Template\n".write(
        to: repo.appendingPathComponent("persona/SOUL.template.md"),
        atomically: true,
        encoding: .utf8
    )
    try "# Fixture\n".write(
        to: repo.appendingPathComponent("persona/SOUL.md"),
        atomically: true,
        encoding: .utf8
    )
    try """
    # Demo Skill

    Use this when Swift skill discovery needs a body fallback.
    """
    .write(to: bodyDir.appendingPathComponent("demo-skill.md"), atomically: true, encoding: .utf8)
    try """
    # Dirty Skill

    Use this when the python daemon should be loaded.
    """
    .write(to: bodyDir.appendingPathComponent("dirty-skill.md"), atomically: true, encoding: .utf8)
    let dirtyRegistryBody = dataSkillBodyDir.appendingPathComponent("dirty-registry.md")
    try """
    # Dirty Registry

    Use this when the python daemon should be loaded.
    """
    .write(to: dirtyRegistryBody, atomically: true, encoding: .utf8)
    let registry: JSONValue = .array([
        .object([
            "id": .string("dirty-registry"),
            "name": .string("dirty-registry"),
            "bodyPath": .string(dirtyRegistryBody.path),
        ]),
    ])
    try registry.serializedData(pretty: false).write(
        to: dataRoot.appendingPathComponent("skills/registry.json")
    )

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let listed = try await tools.dispatch(tool: "list_skills", input: [:], surface: "chat")
    guard case .array(let rows) = listed else {
        Issue.record("expected skill rows")
        return
    }
    #expect(rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("demo-skill")
            && obj["source"] == .string("persona_body")
    })
    #expect(!rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("dirty-skill")
    })
    #expect(!rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("dirty-registry")
    })

    let body = try await tools.dispatch(
        tool: "read_skill",
        input: ["name": .string("demo-skill")],
        surface: "chat"
    )
    guard case .string(let text) = body else {
        Issue.record("expected skill body text")
        return
    }
    #expect(text.contains("Swift skill discovery"))

    await #expect(throws: (any Error).self) {
        _ = try await tools.dispatch(
            tool: "read_skill",
            input: ["name": .string("dirty-skill")],
            surface: "chat"
        )
    }
}

@Test
func chatClient_non_streaming_no_tools_returns_response_and_persists() async throws {
    let root = try makeTempRoot("plain")
    let llm = MockLLMClient(scriptedResponses: ["hello from the model"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
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
    let serializedOutcome = try JSONSerialization.data(withJSONObject: outcome)
    let outcomeText = String(decoding: serializedOutcome, as: UTF8.self)
    #expect(!outcomeText.contains("hello from the model"))
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
    #expect(adapter.calls.allSatisfy { $0.provider == "openai" })
    #expect(adapter.calls.allSatisfy { $0.effort == "medium" })
    #expect(adapter.calls.allSatisfy { $0.tier == "priority" })
    #expect(adapter.calls.allSatisfy { $0.system?.contains("provider=openai") == true })
    #expect(adapter.calls.allSatisfy { $0.system?.contains("provider=xai_oauth_direct") == false })
}

@Test
func chatClient_streamingFreezesOneCheckedRouteAcrossIOSProviderCalls() async throws {
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
    #expect(adapter.calls.allSatisfy { $0.provider == "openai" })
    #expect(adapter.calls.allSatisfy { $0.effort == "medium" })
    #expect(adapter.calls.allSatisfy { $0.tier == "priority" })
    #expect(router.checkedCallCount >= 1)
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
    #expect(progressJoined.contains("[REDACTED_BEARER_TOKEN]"))

    let lines = readJSONL(root, sessionId: "s-stream-tool-redaction")
    #expect(lines.count == 3)
    let persisted = String(describing: lines[1])
    #expect(!persisted.contains(apiKey))
    #expect(!persisted.contains(bearer))
    #expect(persisted.contains("[REDACTED_OPENAI_KEY]"))
    #expect(persisted.contains("[REDACTED_BEARER_TOKEN]"))

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
    #expect(cognitiveJoined.contains("[REDACTED_BEARER_TOKEN]"))
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
    // No verified chatId → legacy `telegram:<chatId>` session still parses.
    #expect(AutonomyGatedDispatcher.resolvedChatId(sessionId: "telegram:111222333") == "111222333")
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

    // Inside a turn the bound live model wins; with no active.json the provider
    // is inferred from the model. This is what agent_introspect reports to Agent.
    let live = await ChatTurnRuntimeContext.$current.withValue(
        .init(model: "claude-opus-4-8", surface: "telegram")
    ) {
        await SwiftToolDispatcher.providerStamp(dataRoot: root)
    }
    guard case .object(let obj) = live else { Issue.record("not an object"); return }
    #expect(obj["model"] == .string("claude-opus-4-8"))
    #expect(obj["name"] == .string("anthropic_oauth_direct"))
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
func chatClient_fileAccess_readOnly_blocks_writes_and_actions_but_keeps_reads() async throws {
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

    for blockedTool in ["write_file", "shell.exec", "mac_quit_app", "persona_write", "persona_append_section"] {
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
    #expect(!names.contains("mac_quit_app"))

    let schemaNames = try await gated.listAvailableToolSchemas().map(\.name)
    #expect(schemaNames.contains("read_file"))
    #expect(schemaNames.contains("git_status"))
    #expect(schemaNames.contains("persona_read"))
    #expect(!schemaNames.contains("write_file"))
    #expect(!schemaNames.contains("persona_write"))
    #expect(!schemaNames.contains("persona_append_section"))
    #expect(!schemaNames.contains("shell.exec"))
    #expect(!schemaNames.contains("mac_quit_app"))
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
        dataRoot: root
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
    try writeTrustPolicy(root, .object([
        "autonomyDefault": .string("deny"),
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
    #expect(firstSystem.contains("PRIOR_CONTEXT_ONLY"))
    #expect(!firstSystem.contains("[user] CURRENT_USER_DUP_TOKEN"))
}

// Native vision (2026-06-11): composeMessage NO LONGER stringifies attachments.
// It returns the raw message; images ride as native content blocks.
@Test
func chatClient_composeMessage_returnsRawMessage_noStringifiedAttachments() async throws {
    let att = MultimodalAttachment(
        type: "image", base64: "AA==", mime: "image/png",
        name: "screenshot.png", byteSize: 4
    )
    let composed = SwiftNativeChatOrchestrationClient.composeMessage(
        message: "look at this", attachments: [att]
    )
    #expect(composed == "look at this")
    #expect(!composed.contains("[attachments:"))
    #expect(!composed.contains("screenshot.png"))
}

// End-to-end: an image attachment on chat() reaches the LLM as a NATIVE .image
// content block on the first user message (not a stringified mention).
private final class MessageCapturingLLM: LLMClient, @unchecked Sendable {
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
        content: "Perfect order of operations.",
        runId: "run-1",
        attachments: []
    )

    let events = await observer.all()
    let event = try #require(events.first)
    #expect(event.kind == .assistantTurnCompleted)
    #expect(event.subject.type == "chat.assistant_turn")
    #expect(event.subject.id.hasPrefix("s-cognition:"))
    #expect(event.metadata["role"] == .string("assistant"))
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

// MARK: - M1 / M2 (honesty sweep, 2026-07-09): transcript writes fail loud
//
// The partial-reply rescue write and the tool-receipt write were both `try?`.
// The rescue write EXISTS to stop silent loss of a truncated reply — swallowing
// its own failure defeated the entire point — and a dropped tool receipt left
// the reloaded transcript showing a reply with no evidence of the tool that
// produced it. Both now log and raise a turn notice on the existing channel.

/// Forces the transcript append to fail by making the target message file a
/// DIRECTORY: bytes cannot be appended to it, and the lock sidecar cannot be
/// created under it either.
private func wedgeTranscriptPath(root: URL, sessionId: String) throws {
    let messages = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: messages.appendingPathComponent("\(sessionId).jsonl"),
        withIntermediateDirectories: true
    )
}

private actor NoticeCapture {
    private var notices: [(kind: String, text: String)] = []
    func record(_ kind: String, _ text: String) { notices.append((kind, text)) }
    func kinds() -> [String] { notices.map(\.kind) }
    func texts() -> [String] { notices.map(\.text) }
}

private func makeClientForNoticeTests(
    root: URL,
    turnTraceBus: TurnTraceBus = .shared,
    publicSafeMode: Bool = false
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
        clock: { Date(timeIntervalSince1970: 1_234) },
        publicSafeMode: publicSafeMode
    )
}

@Test
func persistPartial_writeFailure_raisesTurnNotice() async throws {
    let root = try makeTempRoot("partial-write-fail")
    let sessionId = "s-partial-fail"
    try wedgeTranscriptPath(root: root, sessionId: sessionId)
    let capture = NoticeCapture()

    await makeClientForNoticeTests(root: root).persistPartialIfNeeded(
        sessionId: sessionId,
        runId: "run-1",
        text: "half a reply the user already watched render",
        cancelled: false,
        onNotice: { kind, text in await capture.record(kind, text) }
    )

    let kinds = await capture.kinds()
    #expect(kinds == ["transcript_write_failed"], "a lost partial reply must not be silent")
    let texts = await capture.texts()
    #expect(texts.first?.contains("partial reply") == true)
}

@Test
func persistPartial_success_raisesNoNotice() async throws {
    let root = try makeTempRoot("partial-write-ok")
    let capture = NoticeCapture()

    await makeClientForNoticeTests(root: root).persistPartialIfNeeded(
        sessionId: "s-partial-ok",
        runId: "run-1",
        text: "a partial reply",
        cancelled: true,
        onNotice: { kind, text in await capture.record(kind, text) }
    )

    let kinds = await capture.kinds()
    #expect(kinds.isEmpty, "a successful write must stay quiet")
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("s-partial-ok.jsonl")
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test
func appendToolMessage_writeFailure_isThrowableNotSwallowed() async throws {
    let root = try makeTempRoot("tool-receipt-fail")
    let sessionId = "s-tool-fail"
    try wedgeTranscriptPath(root: root, sessionId: sessionId)

    // M2 is about the CALLER no longer swallowing this with `try?`; pin that the
    // failure is observable at the throw site in the first place.
    await #expect(throws: (any Error).self) {
        try await makeClientForNoticeTests(root: root).appendToolMessage(
            sessionId: sessionId,
            runId: "run-1",
            toolName: "read_file",
            inputJSON: "{}",
            resultSummary: "null",
            ok: true
        )
    }
}

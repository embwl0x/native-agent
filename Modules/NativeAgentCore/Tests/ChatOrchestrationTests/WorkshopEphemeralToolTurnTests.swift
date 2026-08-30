import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import CognitiveSubstrate

private struct EphemeralWorkshopExecutionRouter: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }

    func getProvider(id: String) async throws -> Provider {
        switch id {
        case "openai":
            return Provider(
                id: id,
                modelCatalog: .array([.object(["id": .string("gpt-5.6-sol")])]),
                extras: .object(["default_model": .string("gpt-5.6-sol")])
            )
        case "anthropic":
            return Provider(
                id: id,
                modelCatalog: .array([.object(["id": .string("claude-opus-4-8")])]),
                extras: .object(["default_model": .string("claude-opus-4-8")])
            )
        default:
            throw ProviderRoutingError.providerNotFound
        }
    }

    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }

    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }

    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }

    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        [
            "chat": SurfacePreference(
                surface: "chat",
                model: "gpt-5.6-sol",
                reasoningEffort: "max",
                serviceTier: "default"
            ),
            "missions": SurfacePreference(
                surface: "missions",
                model: "claude-opus-4-8",
                reasoningEffort: "low",
                serviceTier: "priority"
            ),
        ]
    }

    func activeProvidersForSurfaces() async -> [String: String] {
        ["chat": "openai", "missions": "anthropic"]
    }
}

private final class EphemeralWorkshopExecutionRecordingAdapter: LLMAdapter, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let model: String
        let surface: String?
        let reasoningEffort: String?
        let serviceTier: String?
        let sessionId: String?
        let traceId: String?
        let system: String?
    }

    let providerId: String
    private let response: String
    private let lock = NSLock()
    private var calls: [Call] = []

    init(providerId: String, response: String) {
        self.providerId = providerId
        self.response = response
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        record(Call(
            model: model,
            surface: LLMCallContext.surface,
            reasoningEffort: LLMCallContext.reasoningEffort,
            serviceTier: LLMCallContext.serviceTier,
            sessionId: LLMCallContext.sessionId,
            traceId: TurnTraceContext.turnId,
            system: system
        ))
        return response
    }

    private func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct EphemeralWorkshopExecutionNoTools: ToolDispatchClient {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .null
    }

    func listAvailableTools() async throws -> [String] { [] }
}

private final class EphemeralWorkshopToolCallingAdapter: LLMAdapter, @unchecked Sendable {
    let providerId = "anthropic"
    private let lock = NSLock()
    private var responses = [
        #"<tool_use id="work-1" name="desk_work_log">{"handle":"desk_1","receipt":"bounded progress"}</tool_use>"#,
        "receipt accepted",
    ]
    private var observedSessionIds: [String?] = []

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        nextResponse(sessionId: LLMCallContext.sessionId)
    }

    private func nextResponse(sessionId: String?) -> String {
        lock.withLock {
            observedSessionIds.append(sessionId)
            return responses.isEmpty ? "receipt accepted" : responses.removeFirst()
        }
    }

    func sessions() -> [String?] {
        lock.withLock { observedSessionIds }
    }
}

private actor EphemeralWorkshopToolIdentityProbe: ToolDispatchClient {
    private var calls: [[String: JSONValue]] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        calls.append(input)
        return .object(["status": .string("ok")])
    }

    func listAvailableTools() async throws -> [String] { ["desk_work_log"] }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [LLMToolSchema(
            name: "desk_work_log",
            description: "Log a work receipt.",
            parametersJSON: Data(#"{"type":"object","properties":{"handle":{"type":"string"},"receipt":{"type":"string"}},"required":["handle","receipt"]}"#.utf8)
        )]
    }

    func captured() -> [[String: JSONValue]] { calls }
}

private actor EphemeralRecoveryLLM: LLMClient {
    private(set) var handle: String?
    private(set) var turnId: String?
    private(set) var recoveredPage: [String: JSONValue]?
    private(set) var providerSessions: [String?] = []
    private var round = 0

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "unused prompt entry" }

    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        round += 1
        providerSessions.append(LLMCallContext.sessionId)
        if round == 1 {
            turnId = TurnTraceContext.turnId
            return #"<tool_use id="large-1" name="read_file">{"path":"fixture-only"}</tool_use>"#
        }
        let lastResult = messages.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content, _) = block { return content }
            return nil
        }.last
        let text = try #require(lastResult)
        guard case .object(let object) = try JSONValue.parse(Data(text.utf8)) else {
            Issue.record("expected structured recovery result"); return "invalid result"
        }
        if round == 2 {
            guard case .string(let value)? = object["result_handle"] else {
                Issue.record("ephemeral large result has no recovery handle"); return "missing recovery handle"
            }
            handle = value
            return "<tool_use id=\"page-1\" name=\"tool_result_page\">{\"result_handle\":\"\(value)\",\"page\":0}</tool_use>"
        }
        recoveredPage = object
        return "large result recovered"
    }
}

private actor EphemeralRecoveryTools: ToolDispatchClient {
    let dispatcher: SwiftToolDispatcher
    private(set) var sessions: [JSONValue?] = []

    init(root: URL) { dispatcher = SwiftToolDispatcher(dataRoot: root) }

    func listAvailableTools() async throws -> [String] { ["read_file", "tool_result_page"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await listAvailableTools().map {
            LLMToolSchema(name: $0, description: "fixture", parametersJSON: Data("{\"type\":\"object\",\"properties\":{}}".utf8))
        }
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        sessions.append(input["__session_id"])
        if tool == "read_file" { return .object(["payload": .string(String(repeating: "large fixture result ", count: 3_000))]) }
        return try await dispatcher.dispatch(tool: tool, input: input, surface: surface)
    }
}

private actor EphemeralWorkshopCognitionProbe: CognitiveRuntimeProviding {
    private var projectionCalls = 0
    private var commitCalls = 0

    func observe(_ event: CognitiveEvent) async {}

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? { nil }

    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection {
        projectionCalls += 1
        let fixedAt = Date(timeIntervalSince1970: 42)
        return CognitiveTurnProjection(
            fixedAt: fixedAt,
            capsule: CognitiveCapsule(
                generatedAt: fixedAt,
                mode: .inject,
                stableKernel: "Resident execution state:",
                dynamicContext: "- Focus: exact ephemeral projection marker",
                provenanceNodeIds: [],
                truncated: false
            ),
            posture: OrganismBehaviorPosture(
                generatedAt: fixedAt,
                enabled: true,
                posture: "careful",
                claimDiscipline: .verifyBeforeCompletion,
                toolStrategy: .preferKnownPath,
                directives: []
            )
        )
    }

    func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async {
        commitCalls += 1
    }

    func counts() -> (projection: Int, commit: Int) {
        (projectionCalls, commitCalls)
    }
}

@Suite("Workshop ephemeral tool turn")
struct WorkshopExecutionEphemeralToolTurnTests {
    @Test(arguments: [false, true])
    func exhaustedEphemeralTurnRequiresTypedCompletionOnlyWhenRequested(requireCompleted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ephemeral-incomplete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = EphemeralWorkshopToolCallingAdapter()
        let router = EphemeralWorkshopExecutionRouter()
        let llm = SwiftNativeLLMClient(router: router, codex: adapter, anthropic: adapter, openAI: adapter,
                                       moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot())
        let tools = EphemeralWorkshopToolIdentityProbe()
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        let engine = SwiftNativeTurnEngine(persona: hermeticPersona(root: root), memory: nil, router: router,
                                          trust: trust, llm: llm, tools: tools, memoryPromoter: nil)
        let client = SwiftNativeChatOrchestrationClient(engine: engine, tools: tools, llm: llm,
                                                       dataRoot: root, trust: trust, toolLoopMaxIterations: 1, promoter: nil)
        do {
            let result = try await client.runEphemeralToolTurn(message: "Log the fixture receipt and return a final report.",
                                                               verifiedSessionId: "workshop:incomplete-fixture",
                                                               requireCompleted: requireCompleted, surface: "workshop")
            #expect(!requireCompleted, "strict native worker must not receive exhaustion as completed text")
            #expect(!result.output.isEmpty, "ordinary ephemeral callers retain their existing fallback")
        } catch let incomplete as EphemeralToolTurnIncomplete {
            #expect(requireCompleted)
            #expect(!incomplete.output.isEmpty)
            #expect(incomplete.reason.contains("without a completed final reply"))
            #expect(incomplete.reason.contains("unverified"))
        }
        #expect(adapter.sessions().count == 1, "incomplete return must not replay the executed tool round")
        #expect(await tools.captured().count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat").path))
    }

    @Test(arguments: [false, true])
    func usesWorkshopExecutionsRouteControlsAndCreatesNoChatSessionState(useAdmittedOverride: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopEphemeralToolTurnTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let router = EphemeralWorkshopExecutionRouter()
        let chat = EphemeralWorkshopExecutionRecordingAdapter(providerId: "openai", response: "chat route result")
        let executions = EphemeralWorkshopExecutionRecordingAdapter(providerId: "anthropic", response: "Workshop synthesis")
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: EphemeralWorkshopExecutionRecordingAdapter(providerId: "codex", response: "wrong-codex-route"),
            anthropic: executions,
            openAI: chat,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let tools = EphemeralWorkshopExecutionNoTools()
        let cognition = EphemeralWorkshopCognitionProbe()
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: router,
            trust: trust,
            llm: llm,
            tools: tools,
            memoryPromoter: nil
        )
        let client = SwiftNativeChatOrchestrationClient(
            engine: engine,
            tools: tools,
            llm: llm,
            dataRoot: root,
            trust: trust,
            promoter: nil,
            cognitiveObserver: cognition,
            cognitiveContextProvider: cognition
        )

        let response = try await client.runEphemeralToolTurn(
            message: "Synthesize the Workshop execution result.",
            model: useAdmittedOverride ? "gpt-5.6-sol" : "",
            reasoningEffort: useAdmittedOverride ? "medium" : "",
            providerID: useAdmittedOverride ? "openai" : nil,
            serviceTierOverride: useAdmittedOverride ? "default" : nil,
            requireCompleted: true,
            surface: "missions"
        )

        let expectedModel = useAdmittedOverride ? "gpt-5.6-sol" : "claude-opus-4-8"
        let expectedEffort = useAdmittedOverride ? "medium" : "low"
        #expect(response.output == (useAdmittedOverride ? "chat route result" : "Workshop synthesis"))
        #expect(response.model == expectedModel)
        #expect(response.reasoningEffort == expectedEffort)
        #expect(response.providerCallCount == 1)
        #expect(response.sessionId == nil)
        #expect((useAdmittedOverride ? executions : chat).snapshot().isEmpty)
        let call = try #require((useAdmittedOverride ? chat : executions).snapshot().first)
        #expect(call.model == expectedModel)
        // The router fake is keyed with the LEGACY `missions` and the caller
        // above asks for `missions` too — yet the surface reaching the provider
        // is the CANONICAL one. One fold at the turn entry, no spelling leaks
        // past it (P2-3).
        #expect(call.surface == "workshop")
        #expect(call.reasoningEffort == expectedEffort)
        #expect(call.serviceTier == (useAdmittedOverride ? "default" : "priority"))
        #expect(call.sessionId == nil)
        #expect(call.traceId == response.runId)
        #expect(call.system?.contains("exact ephemeral projection marker") == true)
        #expect(call.system?.contains("tool_claims: verifyBeforeCompletion") == true)
        let cognitionCounts = await cognition.counts()
        #expect(cognitionCounts.projection == 1)
        #expect(cognitionCounts.commit == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat").path))
    }

    @Test func carriesVerifiedToolIdentityWithoutCreatingAProviderOrChatSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopEphemeralToolIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let router = EphemeralWorkshopExecutionRouter()
        let adapter = EphemeralWorkshopToolCallingAdapter()
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: adapter,
            anthropic: adapter,
            openAI: adapter,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let tools = EphemeralWorkshopToolIdentityProbe()
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root), memory: nil, router: router,
            trust: trust, llm: llm, tools: tools, memoryPromoter: nil
        )
        let client = SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: llm, dataRoot: root,
            trust: trust, promoter: nil
        )

        let response = try await TurnTraceContext.$turnId.withValue("parent-run") {
            let child = try await client.runEphemeralToolTurn(
                message: "Log this bounded Workshop progress.",
                verifiedSessionId: "workshop:reservation-1",
                surface: "workshop"
            )
            #expect(TurnTraceContext.turnId == "parent-run")
            return child
        }

        let call = try #require(await tools.captured().first)
        #expect(call["__session_id"] == .string("workshop:reservation-1"))
        #expect(response.output == "receipt accepted")
        #expect(response.sessionId == nil)
        #expect(adapter.sessions().allSatisfy { $0 == nil })
        let traceText = try String(contentsOf: root.appendingPathComponent("traces/events.jsonl"), encoding: .utf8)
        let traceRows = try traceText.split(separator: "\n").compactMap { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let toolTrace = try #require(traceRows.first { $0["title"] as? String == "desk_work_log" })
        let payload = try #require(toolTrace["payload"] as? [String: Any])
        #expect(payload["turnId"] as? String == response.runId)
        #expect(response.runId != "parent-run")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat").path))
    }

    @Test func ephemeralLargeResultPagesUseToolIdentityAndReleaseSpillAtTurnExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ephemeral-spill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let llm = EphemeralRecoveryLLM()
        let tools = EphemeralRecoveryTools(root: root)
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        let engine = SwiftNativeTurnEngine(persona: hermeticPersona(root: root), memory: nil,
                                          router: EphemeralWorkshopExecutionRouter(), trust: trust,
                                          llm: llm, tools: tools, memoryPromoter: nil)
        let client = SwiftNativeChatOrchestrationClient(engine: engine, tools: tools, llm: llm,
                                                       dataRoot: root, trust: trust, promoter: nil)
        let identity = "ephemeral-fixture:\(UUID().uuidString)"
        let response = try await TurnTraceContext.$turnId.withValue("caller-fixture-turn") {
            try await client.runEphemeralToolTurn(message: "Read and page the fixture result.",
                                                 verifiedSessionId: identity, surface: "workshop")
        }
        #expect(response.output == "large result recovered")
        #expect(response.sessionId == nil)
        #expect(await llm.providerSessions.allSatisfy { $0 == nil })
        #expect(await tools.sessions == [.string(identity), .string(identity)])
        let page = try #require(await llm.recoveredPage)
        #expect(page["status"] == .string("completed"))
        guard case .string(let content)? = page["content"] else { Issue.record("missing retained page"); return }
        #expect(content.contains("large fixture result"))
        #expect(content.utf8.count <= ProviderToolResultRecoveryStore.pageUTF8Bytes)
        let handle = try #require(await llm.handle)
        let turnId = try #require(await llm.turnId)
        let scope = try #require(ProviderToolResultRecoveryStore.Scope(sessionId: identity, turnId: turnId))
        // The existing turn-exit cleanup is deferred. Observe only this exact
        // handle, without resetting the shared store or disturbing siblings.
        var after = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: 0, sessionId: identity, turnId: turnId)
        for _ in 0..<100 {
            if case .object(let object) = after, object["reason"] == .string("result_handle_unavailable") { break }
            try await Task.sleep(for: .milliseconds(10))
            after = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: 0, sessionId: identity, turnId: turnId)
        }
        // Cleanup our own scope on assertion failure as well; never reset all.
        await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
        guard case .object(let released) = after else { Issue.record("missing cleanup receipt"); return }
        #expect(released["reason"] == .string("result_handle_unavailable"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat").path))
    }
}

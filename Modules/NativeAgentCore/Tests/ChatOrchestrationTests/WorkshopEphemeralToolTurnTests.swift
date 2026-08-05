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
    @Test func usesWorkshopExecutionsRouteControlsAndCreatesNoChatSessionState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopEphemeralToolTurnTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let router = EphemeralWorkshopExecutionRouter()
        let chat = EphemeralWorkshopExecutionRecordingAdapter(providerId: "openai", response: "wrong-chat-route")
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
            surface: "missions"
        )

        #expect(response.output == "Workshop synthesis")
        #expect(response.model == "claude-opus-4-8")
        #expect(response.reasoningEffort == "low")
        #expect(response.providerCallCount == 1)
        #expect(response.sessionId == nil)
        #expect(chat.snapshot().isEmpty)
        let call = try #require(executions.snapshot().first)
        #expect(call.model == "claude-opus-4-8")
        // The router fake is keyed with the LEGACY `missions` and the caller
        // above asks for `missions` too — yet the surface reaching the provider
        // is the CANONICAL one. One fold at the turn entry, no spelling leaks
        // past it (P2-3).
        #expect(call.surface == "workshop")
        #expect(call.reasoningEffort == "low")
        #expect(call.serviceTier == "priority")
        #expect(call.sessionId == nil)
        #expect(call.system?.contains("exact ephemeral projection marker") == true)
        #expect(call.system?.contains("tool_claims: verifyBeforeCompletion") == true)
        let cognitionCounts = await cognition.counts()
        #expect(cognitionCounts.projection == 1)
        #expect(cognitionCounts.commit == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat").path))
    }
}

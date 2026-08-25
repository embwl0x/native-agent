import CognitiveSubstrate
import Context
import DreamREMCycle
import Foundation
import NativeAgentCore
import NativeAgentTestSupport
import PersonaEngine
import PersistenceCore
import ProviderRouting
import Testing
import TrustCenter
@testable import ChatOrchestration

// These tests intentionally work at the turn boundary rather than pinning
// implementation details of a single caller.  The contract has several public
// entry points; a spelling or envelope change on just one is enough to give
// Agent a different mind on that lane without producing an ordinary error.

private final class ContractPersona: PersonaEngineProtocol, @unchecked Sendable {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class ContractRouter: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "eval-model", reasoningEffort: "low")]
    }
}

private actor ContractCaptureFlow: ContextTurnPreparing {
    enum Captured: Error { case request }
    private(set) var request: ContextTurnRequest?

    func contextFlowMode() async -> ContextFlowMode { .active }
    func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket? { nil }
    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        self.request = request
        throw Captured.request
    }
}

private struct ContractAttention: CognitiveContextProviding {
    let signals: CognitiveAttentionSignals

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? { nil }
    func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? { signals }
}

private func contractEngine(
    flow: any ContextTurnPreparing,
    signals: CognitiveAttentionSignals
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: ContractPersona(),
        memory: nil,
        router: ContractRouter(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: MockToolDispatchClient(),
        contextFlow: flow,
        cognitiveContextProvider: ContractAttention(signals: signals)
    )
}

private func contractRequest(
    surface: String,
    signals: CognitiveAttentionSignals
) async throws -> ContextTurnRequest {
    let flow = ContractCaptureFlow()
    _ = try await contractEngine(flow: flow, signals: signals).buildTurnContext(
        surface: surface,
        userMessage: "route this turn",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )
    return try #require(await flow.request)
}

@Suite("turn-contract completion evals")
struct TurnContractCompletionEvalTests {
    // Ledger: route.trustedBridgeEnvelopeProjection
    @Test func trustedBridgeProjectionAcceptsEveryRealSenderPrefixAndRejectsUserProse() {
        let root = try? SourceTreeRepoRoot.locate()
        let bridgeSource = root.flatMap { try? String(
            contentsOf: $0.appendingPathComponent("Sources/NativeAgentApp/ClaudeBridge.swift"),
            encoding: .utf8
        ) }
        // The producer's Claude-special case and generic sender envelope are
        // both part of the contract.  Keep the runtime checks below tied to
        // those actual wire shapes instead of silently accepting a stale list.
        #expect(bridgeSource?.contains("[from: claude, via bridge]") == true)
        #expect(bridgeSource?.contains("[from: \\(sender), via bridge]") == true)
        let realBridgePrefixes = [
            "[from: codex, via bridge] inspect the app",
            "[from: claude, via bridge] continue the evals",
        ]
        for envelope in realBridgePrefixes {
            #expect(SwiftNativeChatOrchestrationClient
                .shouldProjectCognitiveStateForTrustedBridgeEnvelope(envelope))
        }
        #expect(SwiftNativeChatOrchestrationClient
            .shouldProjectCognitiveStateForTrustedBridgeEnvelope("  [FROM: CODEX, VIA BRIDGE] normalized  "))
        #expect(!SwiftNativeChatOrchestrationClient
            .shouldProjectCognitiveStateForTrustedBridgeEnvelope("[from: user, via bridge] user supplied prose"))
        #expect(!SwiftNativeChatOrchestrationClient
            .shouldProjectCognitiveStateForTrustedBridgeEnvelope("please continue the evals"))
    }

    // Ledger: turn.ingredient.suppressPursuitIntent
    @Test func workshopSpellingsSuppressPursuitIntentWhileChatRetainsIt() async throws {
        let signals = CognitiveAttentionSignals(
            activeTask: "finish release evidence",
            goal: "ship the reliable build"
        )
        let canonical = try await contractRequest(surface: "workshop", signals: signals)
        let legacy = try await contractRequest(surface: " MISSIONS ", signals: signals)
        let chat = try await contractRequest(surface: "chat", signals: signals)

        #expect(canonical.surface == .workshop)
        #expect(legacy.surface == .workshop)
        #expect(canonical.activeTask == nil)
        #expect(canonical.goal == nil)
        #expect(legacy.activeTask == nil)
        #expect(legacy.goal == nil)
        #expect(chat.activeTask == signals.activeTask)
        #expect(chat.goal == signals.goal)
    }

    // Ledger: turn.contract.surfaceSpellingFold
    @Test func everyPublicTurnEntryPointFoldsLegacyWorkshopSpellingAtItsBoundary() throws {
        #expect(WorkshopSurfaceVocabulary.foldLegacySpelling("missions") == "workshop")
        #expect(WorkshopSurfaceVocabulary.foldLegacySpelling(" MISSIONS ") == "workshop")
        #expect(WorkshopSurfaceVocabulary.foldLegacySpelling("chat") == "chat")

        let root = try SourceTreeRepoRoot.locate()
        let entryPoints = [
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestration+TurnEngine.swift",
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestration+ToolLoop.swift",
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+EphemeralToolTurn.swift",
        ]
        for relativePath in entryPoints {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(
                source.contains("let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)"),
                "\(relativePath) accepts surface: but does not fold legacy workshop spelling at entry"
            )
        }
    }

    // Ledger: turn.ingredient.toolCatalogRowCap
    //
    // This is deliberately a red regression test until production discloses
    // the existing 80-row truncation.  Hiding an available tool from the text
    // compatibility lane is a behavior failure, not an acceptable test cap.
    @Test func textCompatibilityCatalogEitherListsEveryToolOrDisclosesTheOmission() {
        let schemas = (0 ..< 100).map { index in
            LLMToolSchema(
                name: String(format: "eval_tool_%03d", index),
                description: "Hermetic evaluation tool \(index).",
                parametersJSON: Data(#"{"type":"object"}"#.utf8)
            )
        }
        let context = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "eval-model",
            reasoningEffort: "low",
            toolsAvailable: schemas.map(\.name),
            systemPrompt: nil,
            userMessage: "show tools",
            toolSchemas: schemas
        )
        let rendered = SwiftNativeTurnEngine.withTextToolCompatibilityInstructions(
            nil,
            context: context
        )
        let everySchemaIsVisible = schemas.allSatisfy {
            rendered.contains("- \($0.name)")
        }
        let omissionIsDisclosed = rendered.contains("more tools not listed")
            && rendered.contains("tool_load")

        #expect(
            everySchemaIsVisible || omissionIsDisclosed,
            "text compatibility hid \(schemas.count) available schemas without a counted tool_load disclosure"
        )
    }
}

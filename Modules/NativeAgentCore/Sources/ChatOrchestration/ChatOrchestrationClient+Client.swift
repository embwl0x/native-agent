import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate

// MARK: - SwiftNative impl

struct StructuredChatExecution: Sendable {
    let response: ChatResponse
    let turn: TurnEngineResult
}

/// SwiftNative ChatOrchestrationClient — composes the in-process Swift
/// building blocks into a single chat()/chatStream() surface.
public actor SwiftNativeChatOrchestrationClient: ChatOrchestrationClient {
    let engine: SwiftNativeTurnEngine
    let tools: any ToolDispatchClient
    let llm: any LLMClient
    let streamingLLM: (any StreamingLLMClient)?
    let history: SessionHistoryReader
    let persistence: any PersistenceCoreProtocol
    let dataRoot: URL
    let activeToolsStore: ActiveToolsStore
    let turnTraceBus: TurnTraceBus
    let trust: SwiftNativeTrustCenter
    let approvalFiler: (any ApprovalFiler)?
    let approvalTimeoutSeconds: Double
    let historyLimit: Int
    let toolLoopMaxIterationsOverride: Int?
    let promoter: (any MemoryPromoting)?
    let cognitiveObserver: (any CognitiveEventObserving)?
    let cognitiveContextProvider: (any CognitiveContextProviding)?
    let providerLifecycleObserverInstalled: Bool
    let autocompactionConfig: ChatSessionAutocompactionConfig
    let clock: @Sendable () -> Date
    let publicSafeMode: Bool

    public init(
        engine: SwiftNativeTurnEngine,
        tools: any ToolDispatchClient,
        llm: any LLMClient,
        streamingLLM: (any StreamingLLMClient)? = nil,
        history: SessionHistoryReader = SessionHistoryReader(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        activeToolsStore: ActiveToolsStore? = nil,
        turnTraceBus: TurnTraceBus? = nil,
        trust: SwiftNativeTrustCenter? = nil,
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        historyLimit: Int = 40,
        toolLoopMaxIterations: Int? = nil,
        promoter: (any MemoryPromoting)? = nil,
        cognitiveObserver: (any CognitiveEventObserving)? = nil,
        cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
        providerLifecycleObserverInstalled: Bool = false,
        autocompactionConfig: ChatSessionAutocompactionConfig = .productionDefault(),
        clock: @escaping @Sendable () -> Date = { Date() },
        publicSafeMode: Bool = false
    ) {
        self.engine = engine
        self.tools = tools
        self.llm = llm
        self.streamingLLM = streamingLLM
        self.history = history
        self.persistence = persistence
        self.dataRoot = dataRoot
        // The engine and client participate in one tool loop. Default to the
        // engine's exact store rather than independently deriving another
        // actor from dataRoot; direct test/custom constructions therefore
        // cannot split same-turn load and cleanup state across two owners.
        self.activeToolsStore = activeToolsStore ?? engine.activeToolsStore
        self.turnTraceBus = turnTraceBus ?? engine.turnTraceBus
        // Resolve trust against the SAME dataRoot the client is bound to.
        // Default params can't reference other params in Swift, so this is an
        // optional-then-resolve seam: production callers that pass nothing AND
        // a default dataRoot get the identical SwiftNativeTrustCenter() they
        // got before; tests that pass an override dataRoot stay hermetic.
        self.trust = trust ?? SwiftNativeTrustCenter(dataRoot: dataRoot)
        self.approvalFiler = approvalFiler
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
        self.historyLimit = historyLimit
        self.toolLoopMaxIterationsOverride = toolLoopMaxIterations
        self.promoter = promoter
        self.cognitiveObserver = cognitiveObserver
        let runtime = cognitiveObserver as? (any CognitiveRuntimeProviding)
        self.cognitiveContextProvider = cognitiveContextProvider ?? runtime
        self.providerLifecycleObserverInstalled = providerLifecycleObserverInstalled
        self.autocompactionConfig = autocompactionConfig
        self.clock = clock
        self.publicSafeMode = publicSafeMode
    }

    // MARK: chat (non-streaming)

    public func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        suppressUserAppend: Bool
    ) async throws -> ChatResponse {
        return try await chat(
            message: message,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: attachments,
            persona: nil,
            suppressUserAppend: suppressUserAppend
        )
    }

    public func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool
    ) async throws -> ChatResponse {
        return try await _chat(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: nil
        )
    }

    public func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: ChatOrchestrationProgressHandler?
    ) async throws -> ChatResponse {
        return try await _chat(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: progress
        )
    }

    public func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        suppressUserAppend: Bool
    ) async throws -> ChatResponse {
        return try await _chat(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: "chat",
            suppressUserAppend: suppressUserAppend,
            progress: nil
        )
    }

    private func _chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: ChatOrchestrationProgressHandler?
    ) async throws -> ChatResponse {
        let admission = try await engine.checkedRouteAdmission(
            for: surface,
            requestedModel: model,
            requestedReasoningEffort: reasoningEffort
        )
        return try await LLMCallContext.$admittedModel.withValue(admission.modelId) {
        try await LLMCallContext.$providerId.withValue(admission.providerId) {
        try await LLMCallContext.$reasoningEffort.withValue(admission.reasoningEffort) {
        try await LLMCallContext.$serviceTier.withValue(admission.serviceTier) {
            if try await shouldUseAnthropicTextStreamingCompatibility(
                model: admission.modelId,
                surface: surface
            ) {
                let execution = try await executeTextStreamingCompatibilityChat(
                    message: message,
                    sessionId: sessionId,
                    model: admission.modelId,
                    reasoningEffort: admission.reasoningEffort,
                    fileAccess: fileAccess,
                    attachments: attachments,
                    persona: persona,
                    surface: surface,
                    suppressUserAppend: suppressUserAppend,
                    progress: progress
                )
                var response = execution.response
                let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
                response.requestedModel = requested.isEmpty ? nil : requested
                return response
            }

            let execution = try await executeStructuredChat(
                message: message,
                sessionId: sessionId,
                model: admission.modelId,
                reasoningEffort: admission.reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                persistToolMessages: false,
                progress: progress
            )
            var response = execution.response
            let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
            response.requestedModel = requested.isEmpty ? nil : requested
            return response
        }
        }
        }
        }
    }
}

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
    /// See the protocol requirement: the turn started the promotion after its
    /// assistant append; the surface that delivered the reply drains it here.
    /// OPTIONAL, and starts nothing — no ticket, so this only awaits what is
    /// already running and can never adopt a concurrent turn's pending capture
    /// (Astra comb 3 review, findings 1 and 2, 2026-09-12).
    public func drainDeferredMemoryPromotion() async {
        await engine.awaitDeferredMemoryPromotion()
    }

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
    let turnWallClockSecondsOverride: TimeInterval?
    let promoter: (any MemoryPromoting)?
    let cognitiveObserver: (any CognitiveEventObserving)?
    let cognitiveContextProvider: (any CognitiveContextProviding)?
    let providerLifecycleObserverInstalled: Bool
    let autocompactionConfig: ChatSessionAutocompactionConfig
    let clock: @Sendable () -> Date

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
        turnWallClockSeconds: TimeInterval? = nil,
        promoter: (any MemoryPromoting)? = nil,
        cognitiveObserver: (any CognitiveEventObserving)? = nil,
        cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
        providerLifecycleObserverInstalled: Bool = false,
        autocompactionConfig: ChatSessionAutocompactionConfig = .productionDefault(),
        clock: @escaping @Sendable () -> Date = { Date() }
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
        self.turnWallClockSecondsOverride = turnWallClockSeconds
        self.promoter = promoter
        self.cognitiveObserver = cognitiveObserver
        let runtime = cognitiveObserver as? (any CognitiveRuntimeProviding)
        self.cognitiveContextProvider = cognitiveContextProvider ?? runtime
        self.providerLifecycleObserverInstalled = providerLifecycleObserverInstalled
        self.autocompactionConfig = autocompactionConfig
        self.clock = clock
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
        // v2Prefix: the adapters read ONLY the task-local override (never
        // `.effective`), so EVERY outer turn entry has to resolve it once and
        // bind it. This is the non-streaming entry — the streaming facade wraps
        // its own; an entry that forgot would silently ship v1 wire layout for a
        // v2-shaped body.
        let prefixShape = ConversationPrefixShape.effective
        let prefixTelemetrySink = ConversationPrefixTelemetrySink()
        return try await ConversationPrefixTelemetry.$sink.withValue(prefixTelemetrySink) {
        try await ConversationPrefixShape.$override.withValue(prefixShape) {
        try await LLMCallContext.$admittedModel.withValue(admission.modelId) {
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
                    // Saved conversational evidence must not depend on whether
                    // this caller consumes live progress (bridge vs. Telegram).
                    persistToolMessages: true,
                    progress: progress,
                    noticeSink: { kind, text in await progress?(.notice(kind: kind, text: text)) }
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
    }
}

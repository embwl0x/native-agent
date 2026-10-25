import AuthoredCapabilities
import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
// Blueprint: | `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `chat`, `chatExecution`; `StructuredChatExecution` carries the response and typed success/failure; `withCurrentChatModel` admits the current Chat pick at a wake's `model.call`, so a run that never thinks needs no model; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |

// MARK: - SwiftNative impl

struct StructuredChatExecution: Sendable {
    var response: ChatResponse
    let turn: Result<TurnEngineResult, any Error>

    func responseOrThrow() throws -> ChatResponse {
        _ = try turn.get()
        return response
    }
}

/// SwiftNative ChatOrchestrationClient — composes the in-process Swift
/// building blocks into a single chat()/chatStream() surface.
public actor SwiftNativeChatOrchestrationClient: ChatOrchestrationClient {
    let engine: SwiftNativeTurnEngine
    let tools: any ToolDispatchClient
    let llm: any LLMClient
    let history: SessionHistoryReader
    let persistence: any PersistenceCoreProtocol
    let dataRoot: URL
    let turnTraceBus: TurnTraceBus
    let trust: SwiftNativeTrustCenter
    let approvalFiler: (any ApprovalFiler)?
    let approvalTimeoutSeconds: Double
    let historyLimit: Int
    let continuationCapabilityProfile: String?
    let cognitiveObserver: (any CognitiveEventObserving)?
    let cognitiveContextProvider: (any CognitiveContextProviding)?
    let providerLifecycleObserverInstalled: Bool
    let autocompactionConfig: ChatSessionAutocompactionConfig
    let clock: @Sendable () -> Date

    /// Parts waking between turns use the same client and checked Chat pick,
    /// read at each `model.call`: a run that never thinks needs no model.
    public func withCurrentChatModel<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        // A wake inherits no turn's model: it is chosen fresh at its model.call.
        try await ProviderTurnChoice.$current.withValue(nil) {
        try await LLMCallContext.$admittedModel.withValue(nil) {
        try await LLMCallContext.$surface.withValue("chat") {
        try await SkillRunContext.$admitModel.withValue({ call in
            try await self.withModelContext(try await self.engine.checkedRouteAdmission(for: "chat"), surface: "chat", call)
        }, operation: body)
        }
        }
        }
    }

    func withModelContext<T: Sendable>(_ admission: TurnRouteAdmission, surface: String,
                                     _ body: () async throws -> T) async rethrows -> T {
        try await LLMCallContext.$client.withValue(llm) {
        try await LLMCallContext.$surface.withValue(surface) {
        try await LLMCallContext.$admittedModel.withValue(admission.modelId) {
        try await LLMCallContext.$providerId.withValue(admission.providerId) {
        try await LLMCallContext.$reasoningEffort.withValue(admission.reasoningEffort) {
        try await LLMCallContext.$serviceTier.withValue(admission.serviceTier, operation: body)
        } } } } }
    }

    public init(
        engine: SwiftNativeTurnEngine,
        tools: any ToolDispatchClient,
        llm: any LLMClient,
        history: SessionHistoryReader? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        turnTraceBus: TurnTraceBus? = nil,
        trust: SwiftNativeTrustCenter? = nil,
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        historyLimit: Int = 400,
        continuationCapabilityProfile: String? = nil,
        cognitiveObserver: (any CognitiveEventObserving)? = nil,
        cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
        providerLifecycleObserverInstalled: Bool = false,
        autocompactionConfig: ChatSessionAutocompactionConfig = .productionDefault(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        // Reuse the executable parser; malformed or unknown calls remain actions.
        RunawayOutputDetector.registerReadOnlyCalls { block in
            let calls = ToolCallParser.parse(block, parseInvoke: true, recordShims: false)
            guard calls.count == 1, let call = calls.first, call.undeclaredKeys.isEmpty else { return false }
            if call.name == "app" { return RunawayOutputDetector.isAppReadOnly(call.input) }
            return ParallelToolDispatch.isParallelSafe(internalToolName: call.name, input: call.input)
        }
        self.engine = engine
        self.tools = tools
        self.llm = llm
        self.history = history ?? SessionHistoryReader(dataRoot: dataRoot)
        self.persistence = persistence
        self.dataRoot = dataRoot
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
        self.continuationCapabilityProfile = continuationCapabilityProfile
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
        return try await chatExecution(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: nil
        ).responseOrThrow()
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
        return try await chatExecution(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: progress
        ).responseOrThrow()
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
        return try await chatExecution(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: "chat",
            suppressUserAppend: suppressUserAppend,
            progress: nil
        ).responseOrThrow()
    }

    func chatExecution(
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
    ) async throws -> StructuredChatExecution {
        // A turn that parks on a card has to be able to RECORD that it did, or
        // the tool loop's `waitForInteraction` writes to nil, the waiting
        // terminal is unreachable, and the turn ends with no final at all —
        // which is what reached the Claude bridge as "stream ended without
        // final reply" while the card sat in the conversation (2026-09-13).
        // The bot entry binds its own before calling in; a nested call keeps
        // the outer turn's execution, so this binds at most once per turn.
        // Origin steering and the answered set share this turn's lifetime,
        // independently of whether its execution is already bound.
        if PeerDataTaint.current == nil {
            return try await PeerDataTaint.withScope {
                try await chatExecution(
                    message: message, sessionId: sessionId, model: model,
                    reasoningEffort: reasoningEffort, fileAccess: fileAccess,
                    attachments: attachments, persona: persona, surface: surface,
                    suppressUserAppend: suppressUserAppend, progress: progress
                )
            }
        }
        guard ChatTurnExecution.current != nil else {
            return try await ChatTurnExecution.$current.withValue(ChatTurnExecution()) {
                try await chatExecution(
                    message: message, sessionId: sessionId, model: model,
                    reasoningEffort: reasoningEffort, fileAccess: fileAccess,
                    attachments: attachments, persona: persona, surface: surface,
                    suppressUserAppend: suppressUserAppend, progress: progress
                )
            }
        }
        return try await StandingBotContinuity.withSessionContract(sessionID: sessionId, dataRoot: dataRoot) {
        let admission = try await engine.checkedRouteAdmission(
            for: surface,
            requestedModel: model,
            requestedReasoningEffort: reasoningEffort
        )
        let prefixTelemetrySink = ConversationPrefixTelemetrySink()
        return try await ConversationPrefixTelemetry.$sink.withValue(prefixTelemetrySink) {
        try await withModelContext(admission, surface: surface) {
            var execution = try await executeStructuredChatStreaming(
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
                // chat() callers await the reply; deltas they draw (Telegram's
                // draft) are a preview, not the answer.
                progress: progress,
                noticeSink: { kind, text in await progress?(.notice(kind: kind, text: text)) }
            )
            let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
            execution.response.requestedModel = requested.isEmpty ? nil : requested
            return execution
        }
        }
        }
    }
}

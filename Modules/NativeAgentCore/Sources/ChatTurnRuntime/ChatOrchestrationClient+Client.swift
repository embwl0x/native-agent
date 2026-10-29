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
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
// Blueprint: | `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `chat`, `chatExecution`; `StructuredChatExecution` carries the response and typed success/failure; `withCurrentChatModel` admits the current Chat pick at a wake's `model.call`, so a run that never thinks needs no model; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |

// MARK: - SwiftNative impl

package struct StructuredChatExecution: Sendable {
    package var response: ChatResponse
    let turn: Result<TurnEngineResult, any Error>

    func responseOrThrow() throws -> ChatResponse {
        _ = try turn.get()
        return response
    }
}

/// SwiftNative ChatOrchestrationClient — composes the in-process Swift
/// building blocks into a single chat()/chatStream() surface.
public actor SwiftNativeChatOrchestrationClient {
    let engine: SwiftNativeTurnEngine
    let tools: any ToolDispatchClient
    let llm: any LLMClient
    let history: SessionHistoryReader
    let dataRoot: URL
    public nonisolated let turnTraceBus: TurnTraceBus
    let approvalFiler: (any ApprovalFiler)?
    let approvalTimeoutSeconds: Double
    let historyLimit: Int
    let continuationCapabilityProfile: String?
    let cognitiveRuntime: (any CognitiveRuntimeProviding)?
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
            try await self.withModelContext(try await self.engine.router.checkedRouteAdmission(for: "chat"), surface: "chat", call)
        }, operation: body)
        }
        }
        }
    }

    func withModelContext<T: Sendable>(_ admission: TurnRouteAdmission, surface: String,
                                     _ body: () async throws -> T) async rethrows -> T {
        try await LLMCallContext.$client.withValue(llm) {
        try await LLMCallContext.$surface.withValue(surface) {
        try await admission.withModelContext(body)
        } }
    }

    public init(
        engine: SwiftNativeTurnEngine,
        tools: any ToolDispatchClient,
        llm: any LLMClient,
        history: SessionHistoryReader? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        turnTraceBus: TurnTraceBus? = nil,
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        historyLimit: Int = 400,
        continuationCapabilityProfile: String? = nil,
        cognitiveRuntime: (any CognitiveRuntimeProviding)? = nil,
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
        self.dataRoot = dataRoot
        self.turnTraceBus = turnTraceBus ?? engine.turnTraceBus
        self.approvalFiler = approvalFiler
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
        self.historyLimit = historyLimit
        self.continuationCapabilityProfile = continuationCapabilityProfile
        self.cognitiveRuntime = cognitiveRuntime
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
        persona: String? = nil,
        surface: String = "chat",
        suppressUserAppend: Bool,
        progress: TurnEventSink? = nil
    ) async throws -> ChatResponse {
        return try await chatExecution(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: progress
        ).responseOrThrow()
    }

    package func chatExecution(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: TurnEventSink?
    ) async throws -> StructuredChatExecution {
        // Every turn owns execution and peer provenance, preserving outer scopes.
        return try await PeerDataTaint.withScope {
        try await ChatTurnExecution.$current.withValue(ChatTurnExecution.current ?? ChatTurnExecution()) {
        return try await StandingBotContinuity.withSessionContract(sessionID: sessionId, dataRoot: dataRoot) {
        let admission = try await engine.router.checkedRouteAdmission(
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
            if case .success = execution.turn, let suffix = TurnSettle.takeStreamSuffix() {
                await progress?(.delta(suffix))
            }
            let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
            execution.response.requestedModel = requested.isEmpty ? nil : requested
            return execution
        }
        }
        }
        }
        }
    }
}

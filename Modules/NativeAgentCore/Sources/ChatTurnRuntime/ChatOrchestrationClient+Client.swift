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
    let clock: @Sendable () -> Date

    /// The wake's host receives a lazy admission dependency. Only its
    /// `model.call` invokes it, passing the turn that call serves.
    public func withCurrentChatModel<T: Sendable>(turn: Turn,
        _ body: @Sendable (Turn, @escaping @Sendable (Turn) async throws -> Turn) async throws -> T
    ) async rethrows -> T {
        let wake = turn.with(\.client, llm).with(\.admission, nil).with(\.providerChoice, nil)
        let admit: @Sendable (Turn) async throws -> Turn = { [self] turn in
            let admission = try await self.engine.router.checkedRouteAdmission(for: "chat")
            return try await self.withModelContext(admission, surface: "chat", turn: turn) { $0 }
        }
        return try await body(wake, admit)
    }

    func withModelContext<T: Sendable>(_ admission: TurnRouteAdmission, surface: String,
        turn: Turn, _ body: (Turn) async throws -> T
    ) async throws -> T {
        guard let provider = admission.providerId else {
            throw ProviderRoutingError.configurationFailed("The turn's admitted provider is unavailable.")
        }
        let held = turn.with(\.client, llm).with(\.admission,
            ModelAdmission(provider: provider, model: admission.modelId,
                reasoningEffort: admission.reasoningEffort, serviceTier: turn.requestedServiceTier ?? admission.serviceTier))
        return try await body(held)
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
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        // Reuse the executable parser; malformed or unknown calls remain actions.
        RunawayOutputDetector.registerReadOnlyCalls { block, turn in
            let calls = ToolCallParser.parse(block, parseInvoke: true, recordShims: false)
            guard calls.count == 1, let call = calls.first, call.undeclaredKeys.isEmpty else { return false }
            if call.name == "app" { return RunawayOutputDetector.isAppReadOnly(call.input, turn: turn) }
            return ParallelToolDispatch.isParallelSafe(internalToolName: call.name, input: call.input, turn: turn)
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
        progress: TurnEventSink? = nil,
        turn: Turn,
        serviceTier: String? = nil,
        work: ChatTurnWork = .init()
    ) async throws -> ChatResponse {
        return try await chatExecution(
            message: message, sessionId: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess,
            attachments: attachments, persona: persona, surface: surface,
            suppressUserAppend: suppressUserAppend,
            progress: progress, turn: turn, serviceTier: serviceTier, work: work
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
        progress: TurnEventSink?,
        turn: Turn,
        serviceTier: String? = nil,
        work: ChatTurnWork = .init()
    ) async throws -> StructuredChatExecution {
        var turn = turn
        turn.peerSteering = turn.peerSteering ?? PeerDataTaint()
        turn.execution = turn.execution ?? ChatTurnExecution()
        if let serviceTier { turn = turn.with(\.requestedServiceTier, serviceTier) }
        turn.fileAccess = fileAccess
        turn.userText = message
        return try await StandingBotContinuity.withSessionContract(
            sessionID: sessionId, dataRoot: dataRoot, turn: turn) { turn in
            let choice = turn.botContract?.choice ?? turn.providerChoice
            let admission = try await engine.router.checkedRoutingSnapshot().routeAdmission(
                for: surface, requestedModel: model, requestedReasoningEffort: reasoningEffort, choice: choice)
            guard let admittedReasoningEffort = admission.reasoningEffort else {
                throw ProviderRoutingError.configurationFailed("The turn's admitted reasoning effort is unavailable.")
            }
            var work = work
            work.prefixTelemetry = ConversationPrefixTelemetrySink()
            return try await withModelContext(admission, surface: surface, turn: turn) { turn in
                var execution = try await executeStructuredChatStreaming(
                    message: message, sessionId: sessionId, model: admission.modelId,
                    reasoningEffort: admittedReasoningEffort, fileAccess: fileAccess,
                    attachments: attachments, persona: persona, surface: surface,
                    suppressUserAppend: suppressUserAppend, progress: progress,
                    turn: turn, work: work)
                let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
                execution.response.requestedModel = requested.isEmpty ? nil : requested
                return execution
            }
        }
    }
}

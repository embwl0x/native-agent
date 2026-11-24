import SenseCore
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import MindCore
import ProviderRouting
import MacNerves
import NativeAgentShared
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
    let sessionDelivery: SessionTurnDelivery.Resolver?
    nonisolated let liveTurns: ChatLiveTap?
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
            return try await self.withModelContext(admission, turn: turn) { $0 }
        }
        return try await body(wake, admit)
    }

    func withModelContext<T: Sendable>(_ admission: TurnRouteAdmission,
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
        sessionDelivery: SessionTurnDelivery.Resolver?,
        liveTurns: ChatLiveTap?,
        turnTraceBus: TurnTraceBus? = nil,
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        historyLimit: Int = 400,
        continuationCapabilityProfile: String? = nil,
        cognitiveRuntime: (any CognitiveRuntimeProviding)? = nil,
        providerLifecycleObserverInstalled: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.tools = tools
        self.llm = llm
        self.history = history ?? SessionHistoryReader(dataRoot: dataRoot)
        self.dataRoot = dataRoot
        self.sessionDelivery = sessionDelivery
        self.liveTurns = liveTurns
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
        turn.messageDecisionCalls = turn.messageDecisionCalls ?? MessageDecisionCalls()
        turn.execution = turn.execution ?? ChatTurnExecution()
        if let serviceTier { turn = turn.with(\.requestedServiceTier, serviceTier) }
        turn.fileAccess = fileAccess
        turn.userText = message
        return try await StandingBotContinuity.withSessionContract(
            sessionID: sessionId, dataRoot: dataRoot, turn: turn) { turn in
            let snapshot = try await engine.router.checkedRoutingSnapshot()
            var choice = turn.botContract?.choice ?? turn.providerChoice
            if choice == nil, let bound = Self.requestOnlyModel(turn.modelOverride) {
                // The turn keeps its own Fast and effort (the requested one, else the saved one, else the default level); only the account and
                // model are the card's. The effort is always a real level: "default" names no level a provider takes.
                let saved = try? snapshot.routeAdmission(for: surface, requestedModel: model, requestedReasoningEffort: reasoningEffort)
                let effort = [reasoningEffort, saved?.reasoningEffort ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && $0 != "default" } ?? DEFAULT_REASONING_EFFORT
                choice = ProviderTurnChoice(provider: bound.providerID, model: bound.model, reasoningEffort: effort,
                    fast: (turn.requestedServiceTier ?? saved?.serviceTier) == "priority")
            }
            let admission = try snapshot.routeAdmission(
                for: surface, requestedModel: model, requestedReasoningEffort: reasoningEffort, choice: choice)
            guard let admittedReasoningEffort = admission.reasoningEffort else {
                throw ProviderRoutingError.configurationFailed("The turn's admitted reasoning effort is unavailable.")
            }
            var work = work
            work.prefixTelemetry = ConversationPrefixTelemetrySink()
            return try await withModelContext(admission, turn: turn) { turn in
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

    /// A model card the turn itself raised, answered "for this one", binds the continued turn: it runs on the chosen account and model, at
    /// the turn's own effort level, and nothing saved changes. A card a tool raised (an image's) binds only that tool's call.
    nonisolated static func requestOnlyModel(_ bound: InlineInteractionModelOverride.Binding?) -> InlineInteractionModelOverride.Binding? {
        guard let bound, bound.drivesTurn, !bound.providerID.isEmpty, !bound.model.isEmpty,
              ProviderSurfaceGroups.all.contains(where: { $0.id == bound.group }) else { return nil }
        return bound
    }
}

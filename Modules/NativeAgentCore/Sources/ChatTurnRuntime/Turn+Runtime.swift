import Foundation
import NativeAgentCore
import NativeAgentShared
import TurnTrace
import StandingBots
import ChatToolRuntime
import ChatTurnContracts
import PersistenceCore
import Desk
import Senses
import Context
import ProviderRouting
import ChatSessionWork
import Dispatcher
import TrustCenter
// Blueprint: | `Turn+Runtime.swift` | `Turn` holds runtime state; `ChatTurnWork` holds operation dependencies and LLMCall refinement |

private enum ResumingCheckpointPart: NativeAgentCore.TurnPart { static let unset: TurnCheckpoint? = nil }
private enum InvocationIDPart: NativeAgentCore.TurnPart { static let unset: String? = nil }
private enum StandingBotPart: NativeAgentCore.TurnPart { static let unset: BotDefinition? = nil }
private enum BotContractPart: NativeAgentCore.TurnPart { static let unset: BotChatContract? = nil }
private enum LineInstructionsPart: NativeAgentCore.TurnPart { static let unset: String? = nil }
private enum ObservationPart: NativeAgentCore.TurnPart { static let unset: ToolLoopTraceObservation? = nil }
private enum QueryUserMessagePart: NativeAgentCore.TurnPart { static let unset: String? = nil }
private enum RequestedServiceTierPart: NativeAgentCore.TurnPart { static let unset: String? = nil }
private enum AdmissionTokenPart: NativeAgentCore.TurnPart { static let unset: UUID? = nil }

/// One chat execution's operation state and injected owners, passed down its
/// call stack. A nested/private execution explicitly replaces the owners it
/// does not share. None of these values is a turn identity or a global scope.
public struct ChatTurnWork: Sendable {
    /// The invocation owns the ceilings; work reads and refines that same chain.
    package var deadlines: OperationDeadlines {
        get { toolInvocation.deadlines }
        set { toolInvocation.deadlines = newValue }
    }
    var checkpoint: TurnCheckpointWriter?
    var resumedRows: [ChatMessage] = []
    /// The invocation owns the journal; nil is an explicit clear, including
    /// when a dispatcher replaces its captured work with an incoming invocation.
    var journal: DeskContinuationTurn? {
        get { toolInvocation.deskContinuation }
        set { toolInvocation.deskContinuation = newValue }
    }
    var senseReads: SenseTurnReads?
    var preparedContext: ContextPreparedTurn?
    var imageSink: LocalToolImage.Sink?
    var handsBack = false
    var admissionOnly = false
    /// The invocation carries the authored primitive, so a chain built once per turn sees each call's own body.
    var authoredCall: (tool: String, perform: @Sendable () async throws -> JSONValue)? {
        get { toolInvocation.authoredCall }
        set { toolInvocation.authoredCall = newValue }
    }
    var waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue]) async -> JSONValue)?
    var thinking = false
    var botAncestry: Set<UUID> = []
    var botOptions = BotRunOptions()
    var expansionInside = false
    var fit: SessionRequestFit.Handler?
    var prefixTelemetry: ConversationPrefixTelemetrySink?
    package var toolInvocation = ChatToolInvocation()

    public init(deadlines: OperationDeadlines? = nil, handsBack: Bool = false,
        admissionOnly: Bool = false,
        authoredCall: (tool: String, perform: @Sendable () async throws -> JSONValue)? = nil,
        waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue]) async -> JSONValue)? = nil,
        botAncestry: Set<UUID> = [],
        journal: DeskContinuationTurn? = nil,
        toolInvocation: ChatToolInvocation = .init()
    ) {
        self.toolInvocation = toolInvocation
        if let deadlines { self.deadlines = deadlines }
        self.handsBack = handsBack
        self.admissionOnly = admissionOnly
        if let authoredCall { self.authoredCall = authoredCall }
        self.waitForInteraction = waitForInteraction
        self.botAncestry = botAncestry
        if let journal { self.journal = journal }
    }

    func with<Value>(_ path: WritableKeyPath<ChatTurnWork, Value>, _ value: Value) -> ChatTurnWork {
        var work = self
        work[keyPath: path] = value
        return work
    }

    /// Forward the live ceiling chain without freezing its remaining time into
    /// waitDeadline; that separate absolute budget cannot pause or renew.
    var invocation: ChatToolInvocation {
        var invocation = toolInvocation
        invocation.preparedContext = preparedContext ?? invocation.preparedContext
        invocation.imageSink = imageSink ?? invocation.imageSink
        invocation.senseReads = senseReads ?? invocation.senseReads
        invocation.handsBack = handsBack || invocation.handsBack
        invocation.botAncestry.formUnion(botAncestry)
        return invocation
    }
}

extension LLMCall {
    func with<Value>(_ path: WritableKeyPath<LLMCall, Value>, _ value: Value) -> LLMCall {
        var call = self
        call[keyPath: path] = value
        return call
    }
}

extension Turn {
    var requestedServiceTier: String? {
        get { self[RequestedServiceTierPart.self] }
        set { self[RequestedServiceTierPart.self] = newValue }
    }

    /// Refine an admitted route explicitly. Missing model/provider leaves it
    /// unadmitted; a later model request must obtain its own checked admission.
    func admitting(model: String?? = nil, provider: String?? = nil,
        reasoningEffort: String?? = nil, serviceTier: String?? = nil) -> Turn {
        guard let model = model ?? admission?.model,
              let provider = provider ?? admission?.provider else { return with(\.admission, nil) }
        return with(\.admission, ModelAdmission(provider: provider, model: model,
            reasoningEffort: reasoningEffort ?? admission?.reasoningEffort,
            serviceTier: serviceTier ?? admission?.serviceTier))
    }
    /// The checkpoint this turn resumes: its run, session and continuation.
    public var resumingCheckpoint: TurnCheckpoint? {
        get { self[ResumingCheckpointPart.self] }
        set { self[ResumingCheckpointPart.self] = newValue }
    }
    /// The tool invocation running now; its started/terminal cognition events carry it.
    public var invocationID: String? {
        get { self[InvocationIDPart.self] }
        set { self[InvocationIDPart.self] = newValue }
    }
    /// The standing helper this turn runs as.
    public var standingBot: BotDefinition? {
        get { self[StandingBotPart.self] }
        set { self[StandingBotPart.self] = newValue }
    }
    /// The session helper's resolved model, persona and budget contract.
    public var botContract: BotChatContract? {
        get { self[BotContractPart.self] }
        set { self[BotContractPart.self] = newValue }
    }
    /// The agent's own line's written self: it stands in place of the agent's persona text for this turn. Nil is the agent itself.
    public var lineInstructions: String? {
        get { self[LineInstructionsPart.self] }
        set { self[LineInstructionsPart.self] = newValue }
    }
    /// Partial prose and tool evidence kept across throws for the reply's settlement.
    var observation: ToolLoopTraceObservation? {
        get { self[ObservationPart.self] }
        set { self[ObservationPart.self] = newValue }
    }
    /// The transport-authored relevance query for the current request.
    public var queryUserMessage: String? {
        get { self[QueryUserMessagePart.self] }
        set { self[QueryUserMessagePart.self] = newValue }
    }
    /// The admitted turn's serialization and steering ownership token.
    public var admissionToken: UUID? {
        get { self[AdmissionTokenPart.self] }
        set { self[AdmissionTokenPart.self] = newValue }
    }
}

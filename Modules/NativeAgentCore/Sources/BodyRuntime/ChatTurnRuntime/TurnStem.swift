import SenseCore
import MacNerves
import MindCore
import DeskCore
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import NativeAgentShared
// Blueprint: | `TurnStem.swift` | `TurnStem`: one turn's living state, which the stem's stages read and write from the opening to the settlement: its inputs and part, and its mutable state grouped by owner (`Wire`, what goes to the model, with `seeded`/`reseed`; `Owed`, deliveries owed once the model reads them; `Voice`, their words as they stream and are kept, with `retainProse`; `Tally`, the turn's measure); the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated for `took`) |

/// One turn's living state. The stem's stages (`TurnStem+Opening.swift`, `TurnStem+Effects.swift`, `TurnStem+ModelRound.swift`)
/// are engine methods that take it; it lives for one turn and never crosses isolation.
final class TurnStem {
    let surface: String
    let userMessage: String
    let sessionId: String?
    let toolSessionId: String?
    let runId: String?
    let llm: any LLMClient
    let tools: any ToolDispatchClient
    let progress: ToolProgress?
    let onDelivery: (@Sendable () async -> Void)?
    let cancelFlagPath: URL?
    let providerAdmission: (@Sendable () async throws -> Void)?
    let startNs: UInt64
    private(set) var turn: Turn
    let work: ChatTurnWork
    /// The opening's call, with whether this is a thought already applied.
    let call: LLMCall
    let partRounds: AbilityRounds
    let toolCallCodec: ToolCallCodec
    let turnBudget: ContextBudgetPolicy.Resolved
    let turnWindowTokens: Int
    let prefixSink: ConversationPrefixTelemetrySink?
    var replacementUserMessageID: String? { turn.rows.replacementUserMessageID ?? wire.resolvedTurnContext.historyReplaySpec?.replacementUserMessageID }
    let requestDispatched: @Sendable () -> Void
    let dataRoot: URL?

    var part: TurnPart
    let wire: Wire
    let owed: Owed
    let voice: Voice
    let tally: Tally

    /// What goes to the model: the turn's context, its seeded prefix and system, the offered tools and the conversation.
    final class Wire {
        var resolvedTurnContext: TurnContext
        private var seed: ConversationPrefixSeeding.Seed?
        var cortexPrepared: Bool { seed != nil }
        var prefixSeed: ConversationPrefixSeeding.Seed {
            get throws {
                guard let seed else { throw ProviderRoutingError.configurationFailed("The model request has no prepared prefix.") }
                return seed
            }
        }
        var wireSystem: (prompt: String?, segments: SystemPromptSegments?) = (nil, nil)
        var composed: (system: SystemPromptSegments?, tools: [String]?) = (nil, nil)
        var ctx: TurnContext
        var providerTools: ProviderToolNameMap
        var bookkeeping = Task<Void, Never> {}
        var conversation: [LLMMessage] = []

        /// Only visible prose enters the next wire transcript.
        func keep(prose: String) {
            if prose.contains(where: { !$0.isWhitespace }) { conversation.append(.assistantText(prose)) }
        }

        init(opening: TurnContext) {
            resolvedTurnContext = opening
            ctx = opening
            providerTools = ProviderToolNameMap(opening.toolSchemas)
        }

        /// Seed the opening request again when repair selects a version with different system text or tools.
        static func seeded(_ composed: TurnContext, codec toolCallCodec: ToolCallCodec) throws
            -> (ConversationPrefixSeeding.Seed, (prompt: String?, segments: SystemPromptSegments?)) {
            if composed.systemSegments == nil {
                return (ConversationPrefixSeeding.seed(composed), (nil, nil))
            }
            let request = try ConversationPrefixSeeding.request(composed, codec: toolCallCodec)
            return (request.seed, (request.system, request.segments))
        }

        /// Reads the stem's inputs it is handed; `turn` is the stem's own turn.
        func reseed(keeping additional: [LLMMessage], afterToolRound: Bool, turn: Turn, codec toolCallCodec: ToolCallCodec,
                    prefixSink: ConversationPrefixTelemetrySink?, surface: String, sessionId: String?, runId: String?,
                    replacementUserMessageID: String?, dataRoot remPinsDataRoot: URL?) throws {
            let (prefixSeed, system) = try Self.seeded(resolvedTurnContext, codec: toolCallCodec)
            self.seed = prefixSeed
            wireSystem = system
            ctx = prefixSeed.context
            providerTools = ProviderToolNameMap(ctx.toolSchemas)
            conversation = ConversationPrefixSeeding.Request(seed: prefixSeed, system: wireSystem.prompt, segments: wireSystem.segments,
                tools: toolCallCodec.requestTools(providerTools.schemas)).appending(additional).messages
            if afterToolRound {
                LocalToolImage.boundConversation(&conversation)
                turn.execution?.keepPixels(LocalToolImage.imageNames(conversation))
            }
            let seed = prefixSeed
            let telemetry = Task { await SwiftNativeTurnEngine.preparePrefixTelemetry(seed) }
            prefixSink?.setPending(Task { let result = await telemetry.value; return result.snapshot })
            bookkeeping = Task { [remPinsDataRoot] in
                await SwiftNativeTurnEngine.recordDispatchBookkeeping(seed: seed, telemetry: telemetry, sink: prefixSink, surface: surface, sessionId: sessionId,
                    runId: runId, userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot, turn: turn)
            }
        }
    }

    /// Deliveries owed to their owners once the model reads them.
    final class Owed {
        var commitInstructionDelivery: (@Sendable () async throws -> Void)?
        var commitPartsDelivery: (@Sendable (String) -> Void)?
        var contextDeliveryOwed = true
        var cognitiveContextDelivered = false
        // Steered messages reach the queue owner as delivered at the same
        // moment instructions do: the round carrying them produced output.
        var steeringOffers: [ChatTurnSteering.Offer] = []
        var replayedArrivals: Set<String>
        /// The result lines recollection weighed; they become familiar only once the model has read the round that carried them.
        var familiarOwed: [String] = []
        var cameToMindHeld: Set<ContextAtomID> = []
        var agentNow: AgentNowCursor?
        var lastBreath: String?
        var breathActs: Set<String>

        init(commitInstructionDelivery: (@Sendable () async throws -> Void)?, commitPartsDelivery: (@Sendable (String) -> Void)?,
             replayedArrivals: Set<String>, agentNow: AgentNowCursor?, breathActs: Set<String>) {
            self.commitInstructionDelivery = commitInstructionDelivery
            self.commitPartsDelivery = commitPartsDelivery
            self.replayedArrivals = replayedArrivals
            self.agentNow = agentNow
            self.breathActs = breathActs
        }
    }

    /// Her words as they stream and are kept.
    final class Voice {
        var spoken = false
        var visibleText = ""
        var retainedProse = ""
        var workingCommentaryCharacters = 0
        // The words she streams read as the kept reply does (`joinedProse`): words that follow a call start a new paragraph.
        var liveLast: Character?
        var liveBreakOwed = false
        // Her own reply arrives in chunks of one piece of text: only the first chunk after something else starts a paragraph.
        var liveInAuthoredReply = false
        var replyTextSettled = false
        var emittedProviderFirstDelta = false
        var lastMovement: ContinuousClock.Instant?

        /// Keep rounds in their streamed order; commentary can extend only the leading prefix, never pass an answer.
        func retainProse(_ prose: String, commentary: Bool = false) {
            let extendsCommentary = commentary && workingCommentaryCharacters == retainedProse.count
            retainedProse = SwiftNativeTurnEngine.joinedProse(retainedProse, prose)
            if extendsCommentary { workingCommentaryCharacters = retainedProse.count }
        }
    }

    /// The turn's measure.
    final class Tally {
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var counters = TurnEngineResult.LoopCounters()
        var previousRoundFailed = false
        // Account for the whole turn's model tokens, part rounds and longest repeated call stretch.
        let spent = LLMCallTraceRecorder.Tally(LLMCallTraceRecorder.Spend())
        var repeated = (calls: [JSONValue](), call: "", count: 0), longest = (call: "", count: 0)
        // The familiarity nerve fires at most once a turn, and never on a route this turn already met.
        var practiceChecked: Set<String> = [], practiceNoted = false
        var providerCallCount = 0
        var openingAdditionalCharacters = 0
        var providerFailurePending: Bool
        var round: (calls: [ParsedToolCall], raw: String, codec: TextMarkerCodec?, boundary: LLMToolBoundaryReason?)?

        init(providerFailurePending: Bool) {
            self.providerFailurePending = providerFailurePending
        }
    }

    init(surface: String, userMessage: String, sessionId: String?, toolSessionId: String?, runId: String?,
         llm: any LLMClient, tools: any ToolDispatchClient, progress: ToolProgress?, onDelivery: (@Sendable () async -> Void)?,
         cancelFlagPath: URL?, providerAdmission: (@Sendable () async throws -> Void)?, startNs: UInt64,
         turn: Turn, work: ChatTurnWork, call: LLMCall, partRounds: AbilityRounds, toolCallCodec: ToolCallCodec,
         turnBudget: ContextBudgetPolicy.Resolved, turnWindowTokens: Int, prefixSink: ConversationPrefixTelemetrySink?,
         requestDispatched: @escaping @Sendable () -> Void, dataRoot: URL?,
         part: TurnPart, wire: Wire, owed: Owed, voice: Voice, tally: Tally) {
        self.surface = surface
        self.userMessage = userMessage
        self.sessionId = sessionId
        self.toolSessionId = toolSessionId
        self.runId = runId
        self.llm = llm
        self.tools = tools
        self.progress = progress
        self.onDelivery = onDelivery
        self.cancelFlagPath = cancelFlagPath
        self.providerAdmission = providerAdmission
        self.startNs = startNs
        self.turn = turn
        self.work = work
        self.call = call
        self.partRounds = partRounds
        self.toolCallCodec = toolCallCodec
        self.turnBudget = turnBudget
        self.turnWindowTokens = turnWindowTokens
        self.prefixSink = prefixSink
        self.requestDispatched = requestDispatched
        self.dataRoot = dataRoot
        self.part = part
        self.wire = wire
        self.owed = owed
        self.voice = voice
        self.tally = tally
    }

    func dispatchContext(isolation: isolated (any Actor)? = #isolation) async throws -> TurnContext {
        let context = try await part.context.ensurePrepared()
        if turn.offeredTools == nil { turn.offeredTools = Set(context.toolSchemas.map(\.name)) }
        return context
    }

    func observed(_ result: TurnEngineResult, reason: TurnEngineResult.TerminalReason) -> TurnEngineResult {
        return result.observingTerminal(reason: reason, counters: tally.counters, cognitiveContextDelivered: owed.cognitiveContextDelivered)
    }

    func stopCarryingPartial() -> Error {
        TurnEngineError.streamCancelled(
            partial: toolCallCodec.visiblePrefix(in: voice.visibleText),
            underlying: CancellationError())
    }
}

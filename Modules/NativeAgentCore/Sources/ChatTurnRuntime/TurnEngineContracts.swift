import ChatTurnContracts
import ChatSessionWork
import ApprovalInbox
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle
import Context
import CognitiveSubstrate
import ToolRegistry
import TurnTrace
import ChatToolParsing
// Blueprint: | `TurnEngineContracts.swift` | `TurnContext`; `TurnEngineResult`; Prepared context and engine-owned terminal truth |

// MARK: - TurnEngineError

public enum TurnEngineError: Error, LocalizedError {
    case personaLoadFailed(underlying: Error)
    /// Preparation failure ends the turn with its cause and remedy; no stand-in prompt can replace required context.
    case contextLoadFailed(underlying: Error)
    /// A catalog read failure ends the turn; partial or empty tools cannot stand in for unavailable descriptors.
    case toolCatalogLoadFailed(underlying: Error)
    case emptyMessage
    /// Preserve visible partial prose when a provider stream fails.
    case streamInterrupted(partial: String, underlying: Error)
    /// User Stop preserves partial prose with cancelled:true and rethrows CancellationError.
    case streamCancelled(partial: String, underlying: Error)
    /// Report exhaustion of clean turn programs instead of pretending the turn part ran.
    case turnPartFailed(String)
    /// Keep helper admission failure attached to its own single attempt.
    case turnHelperUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .personaLoadFailed(let e):
            return "persona load failed: " + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
        case .contextLoadFailed(let e):
            return "I couldn't load my context for this reply: "
                + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
                + ". Open Diagnostics → Doctor and follow the Context Flow check, then send again."
        case .toolCatalogLoadFailed(let e):
            return "I couldn't load my tools: "
                + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
        case .emptyMessage: return "userMessage was empty or whitespace-only"
        case .streamInterrupted(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .streamCancelled(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .turnPartFailed(let why):
            return """
                turn_part_failed: \(why) The shipped turn part also failed. Read app {action:\"trace.recent\"} for the failing step; repair that \
                cause before starting new work. This turn ended incomplete.
                """
        case .turnHelperUnavailable(let why):
            return "turn_helper_unavailable: \(why) This turn ended before its helper started."
        }
    }
}

// MARK: - ToolDispatchClient

public typealias ToolDispatchClient = ChatTurnContracts.ToolDispatchClient

// MARK: - TurnContext

/// The stem gathers persona, pins, recall and context; turn.js owns their ordering and joins.
public struct TurnReach: Sendable, Equatable {
    public internal(set) var persona = ""
    public internal(set) var guidance = ""
    /// Internal part thoughts receive no injected persona or expression policy.
    public internal(set) var expression: JSONValue = .null
    public internal(set) var pins: [String] = []
    public internal(set) var recall = ""
    public internal(set) var digest = ""
    public internal(set) var packet = ""
    public internal(set) var history = ""
    public internal(set) var facts: [String] = []
    public internal(set) var runtime: JSONValue = .null
}

/// One line of the agent: when its present was last read (nil: not yet, so the next read starts at the agent's last reply here),
/// and whether a peer steers it (words from other doors then stay out).
struct AgentNowCursor: Sendable {
    let at: Date?
    let peer: Bool
}

/// The part owns system composition from these gathered inputs.
public struct TurnContext: Sendable {
    public let surface: String
    /// Carry the exact persona into dispatch so explicit recall shares automatic recall's disclosure boundary.
    public let personaID: String?
    public let personaDocs: [String: String]
    /// Capture source revision before projecting USER for this turn.
    public let personaFingerprint: String
    /// Off mode retains pre-render hits; active mode uses packet provenance.
    public let recalled: [MemoryRecallHit]
    public internal(set) var modelId: String
    public internal(set) var reasoningEffort: String
    /// Immutable route admitted from one checked provider-routing snapshot.
    /// Adapters still reread canonical routing for corruption/revocation, but
    /// a valid mid-turn preference change cannot splice generations.
    public let providerId: String?
    public let serviceTier: String?
    public let toolsAvailable: [String]
    /// Wire-name mapping uses only this filtered offer; name-only dispatchers supply no schema offer.
    public internal(set) var toolSchemas: [LLMToolSchema]
    public internal(set) var systemPrompt: String?
    public let userMessage: String
    /// Keep combined segments equal to systemPrompt so adapter cache boundaries describe the actual sent prompt.
    public internal(set) var systemSegments: SystemPromptSegments?
    /// Image blocks belong only to the current in-flight user message, never cached system segments or later-turn replay.
    public let imageBlocks: [LLMContentBlock]
    /// Pins one immutable ContextFlow generation through the complete
    /// provider/tool loop. nil denotes explicitly selected direct context assembly.
    public let fluidContextTurn: ContextPreparedTurn?
    /// Replay bounded prior turns oldest first so provider prefixes remain byte-stable.
    public internal(set) var historyMessages: [LLMMessage]
    /// Hold the complete volatile mass until user-block keyframe/delta seeding; nil means no split has run.
    public internal(set) var turnVolatileBlock: String?
    /// Replay metadata only for user rows actually included in the history projection.
    package var historyReplaySpec: SessionReplaySpec? = nil
    package var historyRowCharacters: [String: Int] = [:]
    package var replayedTurnContexts: [SentTurnContext] = []
    /// Keep recollection identity independent of turn-varying rendered text.
    package var historyContextWindow = "0:"
    /// Absent measurement stays absent; do not invent a preparation duration.
    public var preparationMs: Int64?
    /// Credit delivered memory only after provider acceptance, never during assembly.
    public internal(set) var usageCreditMemoryIDs: [String] = []
    /// Exact parts stamps carried by this preparation; no state changes until provider output.
    var partsDelivery: (@Sendable (String) -> Void)? = nil
    /// The body line these facts carry; stamped as said only when the provider accepts a context containing it.
    var bodyFelt: BodyFelt.Pending? = nil
    /// Where the agent's present was read for this line; every later step reads only what changed in the agent since.
    var agentNow: AgentNowCursor? = nil
    var cognitiveRuntimeContext: String? = nil
    public internal(set) var turnReach: TurnReach
    /// Keep bounded deduplicated provenance separately from the rendered memory IDs used for delivery credit.
    public var resolvedRecalledIds: [String] {
        var out: [String] = []
        var seen = Set<String>()
        for hit in recalled {
            if case .object(let obj)? = hit.extras,
               case .string(let id)? = obj["id"],
               seen.insert(id).inserted {
                out.append(id)
            }
        }
        for id in fluidContextTurn?.selectedMemoryRecordIDs ?? [] where seen.insert(id).inserted {
            out.append(id)
        }
        return Array(out.prefix(32))
    }

    public init(
        surface: String,
        personaID: String? = nil,
        personaDocs: [String: String],
        personaFingerprint: String,
        recalled: [MemoryRecallHit],
        modelId: String,
        reasoningEffort: String,
        providerId: String? = nil,
        serviceTier: String? = nil,
        toolsAvailable: [String],
        userMessage: String,
        toolSchemas: [LLMToolSchema] = [],
        imageBlocks: [LLMContentBlock] = [],
        fluidContextTurn: ContextPreparedTurn? = nil,
        historyMessages: [LLMMessage] = [],
        turnVolatileBlock: String? = nil,
        preparationMs: Int64? = nil,
        turnReach: TurnReach
    ) {
        self.surface = surface
        self.personaID = personaID
        self.personaDocs = personaDocs
        self.personaFingerprint = personaFingerprint
        self.recalled = recalled
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.providerId = providerId
        self.serviceTier = serviceTier
        self.toolsAvailable = toolsAvailable
        self.toolSchemas = toolSchemas
        self.userMessage = userMessage
        self.imageBlocks = imageBlocks
        self.fluidContextTurn = fluidContextTurn
        self.historyMessages = historyMessages
        self.turnVolatileBlock = turnVolatileBlock
        self.preparationMs = preparationMs
        self.turnReach = turnReach
    }

    func composing(_ system: SystemPromptSegments, tools: [String]?) -> TurnContext {
        var copy = self
        copy.systemSegments = system
        copy.systemPrompt = system.combined
        if let tools { copy.toolSchemas = toolSchemas.filter { tools.contains($0.name) } }
        return copy
    }

    /// Move the complete dynamic segment only after all contributors append, preserving order and bytes before delta selection.
    /// Deliver it after replayed history on the current user row, then store exactly those delivered bytes as metadata.
    /// Rebuild systemPrompt from emptied segments so it remains equal to their combined value.
    /// Append caller-supplied trailing material after the dynamic block; absent segments or volatile text leave the context unchanged.
    public func splittingVolatileBlock(appending trailingSection: String = "") -> TurnContext {
        guard let segments = systemSegments else { return self }
        let volatileBlock = [segments.dynamic, trailingSection]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !volatileBlock.isEmpty else { return self }
        let lifted = SystemPromptSegments(
            stable: segments.stable,
            dynamic: ""
        )
        var copy = self
        copy.systemPrompt = lifted.combined
        copy.systemSegments = lifted
        copy.turnVolatileBlock = volatileBlock
        return copy
    }
}

// MARK: - TurnEngineResult

public struct TurnEngineResult: Sendable {
    public typealias TerminalState = TurnTraceEvent.TerminalState

    public enum TerminalReason: String, Sendable {
        case replyCompleted = "reply_completed"
        case approvalRequired = "approval_required"
        case interactionRequired = "interaction_required"
        case providerRequired = "provider_required"
        case cancelled
        case providerInterrupted = "provider_interrupted"
        case providerFailed = "provider_failed"
        case executionFailed = "execution_failed"
        case incomplete
        case completionUnreported = "completion_unreported"

        public var state: TerminalState {
            switch self {
            case .replyCompleted: return .completed
            case .approvalRequired, .interactionRequired, .providerRequired: return .waiting
            case .cancelled: return .stopped
            case .providerInterrupted, .incomplete, .completionUnreported: return .interrupted
            case .providerFailed, .executionFailed: return .failed
            }
        }
    }

    public struct LoopCounters: Sendable {
        public internal(set) var providerAttemptCount = 0
        public internal(set) var failedProviderAttemptCount = 0
        /// First issued attempt of each loop iteration; retries are separate.
        public internal(set) var providerRoundCount = 0
        public internal(set) var contextOverflowRecoveryCount = 0
        public internal(set) var toolRoundCount = 0
        public internal(set) var roundsAfterToolFailureCount = 0
        public internal(set) var protocolViolationRoundCount = 0
        public internal(set) var emptyReplyRoundCount = 0
    }

    public enum CompletionState: Sendable, Equatable {
        case completed
        case incomplete
    }
    public struct TerminalObservation: Sendable, Equatable {
        public let reasoningEffort: String
        public let toolSchemaCount: Int
        public let contextSource: String
        public let contextSelectedAtomCount: Int
        public let contextPacketCharacters: Int
        public let contextExpandablePointerCount: Int

        public init(
            reasoningEffort: String,
            toolSchemaCount: Int,
            contextSource: String,
            contextSelectedAtomCount: Int,
            contextPacketCharacters: Int,
            contextExpandablePointerCount: Int
        ) {
            self.reasoningEffort = reasoningEffort
            self.toolSchemaCount = max(0, toolSchemaCount)
            self.contextSource = contextSource
            self.contextSelectedAtomCount = max(0, contextSelectedAtomCount)
            self.contextPacketCharacters = max(0, contextPacketCharacters)
            self.contextExpandablePointerCount = max(0, contextExpandablePointerCount)
        }

        init(context: TurnContext) {
            self.init(
                reasoningEffort: context.reasoningEffort,
                toolSchemaCount: context.toolSchemas.count,
                contextSource: context.fluidContextTurn == nil ? "direct" : "fluid_context",
                contextSelectedAtomCount: context.fluidContextTurn?.packet.selectedItems.count ?? 0,
                contextPacketCharacters: context.fluidContextTurn?.packet.characterCount ?? 0,
                contextExpandablePointerCount: context.fluidContextTurn?.packet.expandablePointers.count ?? 0
            )
        }
    }

    public typealias ToolDispatchRecord = ChatTurnContracts.ToolDispatchRecord

    public let reply: String
    public let modelUsed: String
    public let recalledIds: [String]
    public let toolDispatches: [ToolDispatchRecord]
    public let elapsedMs: Int
    /// Only owners with authoritative provider completion counts may supply accounting; unknown stays nil.
    public let providerCallCount: Int?
    /// Terminal truth comes from the engine's evidence, never from nonempty reply prose.
    public let completionState: CompletionState?
    public let terminalReason: TerminalReason?
    public let loopCounters: LoopCounters?
    /// Memory recording and private work released by the saved answer.
    public internal(set) var afterReply: AfterReply?
    /// Retain working commentary on user-facing surfaces; only explicit answer-only callers trim at this recorded boundary.
    public let workingCommentaryCharacters: Int?

    public init(
        reply: String,
        modelUsed: String,
        recalledIds: [String],
        toolDispatches: [ToolDispatchRecord],
        elapsedMs: Int,
        providerCallCount: Int? = nil,
        completionState: CompletionState? = nil,
        afterReply: AfterReply? = nil,
        workingCommentaryCharacters: Int? = nil,
        terminalReason: TerminalReason? = nil,
        loopCounters: LoopCounters? = nil
    ) {
        self.reply = ChatRichContentParser.visibleText(reply)
        self.modelUsed = modelUsed
        self.recalledIds = recalledIds
        self.toolDispatches = toolDispatches
        self.elapsedMs = elapsedMs
        self.providerCallCount = providerCallCount
        self.completionState = completionState
        self.terminalReason = terminalReason
        self.loopCounters = loopCounters
        self.afterReply = afterReply
        self.workingCommentaryCharacters = workingCommentaryCharacters
    }

    func resolvedTerminalReason(dataRoot: URL?) -> TerminalReason {
        if let terminalReason { return terminalReason }
        let approvalDispatches = toolDispatches.filter { ChatToolOutcome.isWaitingApproval($0.result) }
        if !approvalDispatches.isEmpty {
            // Receipts record filing, not whether the approval is still outstanding.
            let approvalIDs = approvalDispatches.compactMap { dispatch -> String? in
                guard case .object(let object) = dispatch.result,
                      case .string(let rawID)? = object["approvalId"] ?? object["approval_id"] else { return nil }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                return id.isEmpty ? nil : id
            }
            guard approvalIDs.count == approvalDispatches.count, let dataRoot,
                  let rows = try? SwiftNativeApprovalInbox(root: dataRoot).pendingUnlocked() else { return .completionUnreported }
            let pendingIDs = Set(rows.map(\.id))
            if approvalIDs.contains(where: pendingIDs.contains) { return .approvalRequired }
        }
        if toolDispatches.contains(where: {
            let reply = ToolResult($0.result)
            return reply.isWaitingInteraction
        }) { return .interactionRequired }
        switch completionState {
        case .completed: return .replyCompleted
        case .incomplete: return .incomplete
        case nil: return .completionUnreported
        }
    }

    func observingTerminal(reason: TerminalReason, counters: LoopCounters) -> Self {
        Self(
            reply: reply, modelUsed: modelUsed, recalledIds: recalledIds,
            toolDispatches: toolDispatches, elapsedMs: elapsedMs,
            providerCallCount: providerCallCount,
            completionState: completionState, afterReply: afterReply,
            workingCommentaryCharacters: workingCommentaryCharacters,
            terminalReason: reason, loopCounters: counters
        )
    }
}

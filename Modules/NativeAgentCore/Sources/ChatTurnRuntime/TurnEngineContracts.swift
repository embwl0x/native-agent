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
// Blueprint: | `TurnEngineContracts.swift` | `TurnContext` value projections with module-scoped setters, immutable admitted routing and retained sent-context/window metadata; `TurnEngineResult` aliases TurnTraceEvent's terminal status vocabulary |

// MARK: - TurnEngineError

public enum TurnEngineError: Error, LocalizedError {
    case personaLoadFailed(underlying: Error)
    /// Context Flow is on but could not prepare this turn's context. The turn
    /// ends here with the cause and the way out, never on a stand-in prompt.
    case contextLoadFailed(underlying: Error)
    /// Listing the turn's tool catalog threw. The turn ends here rather than
    /// running the model with no or partial tools.
    case toolCatalogLoadFailed(underlying: Error)
    case emptyMessage
    /// A failed provider stream carries visible partial prose for persistence.
    case streamInterrupted(partial: String, underlying: Error)
    /// User Stop preserves partial prose with cancelled:true and rethrows CancellationError.
    case streamCancelled(partial: String, underlying: Error)
    /// Her turn part failed with no clean version left to swap in.
    case turnPartFailed(String)
    /// No helper can start to run her turn part, and waiting will not change that.
    case turnHelperUnavailable(String)
    /// A handback wait lost observation or control before it could resume.
    case macControlWaitUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .personaLoadFailed(let e):
            return "persona load failed: " + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
        case .contextLoadFailed(let e):
            return "I couldn't load my context for this reply: "
                + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
                + ". Open Diagnostics → Doctor and follow the Context Flow check, then send again."
                + " To reply without it meanwhile, set Setup → Memory in every reply to Off."
        case .toolCatalogLoadFailed(let e):
            return "I couldn't load my tools: "
                + ((e as? LocalizedError)?.errorDescription ?? String(describing: e))
        case .emptyMessage: return "userMessage was empty or whitespace-only"
        case .streamInterrupted(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .streamCancelled(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .turnPartFailed(let why):
            return "turn_part_failed: \(why) The shipped turn part also failed. Read app {action:\"trace.recent\"} for the failing step; repair that cause before starting new work. This turn ended incomplete."
        case .turnHelperUnavailable(let why):
            return "turn_helper_unavailable: \(why) This turn ended before its helper started."
        case .macControlWaitUnavailable(let why):
            return "I couldn't wait for Mac control to return: \(why) This turn ended without resuming."
        }
    }
}

// MARK: - ToolDispatchClient

public typealias ToolDispatchClient = ChatTurnContracts.ToolDispatchClient

// MARK: - TurnContext

/// What the stem gathers for her turn part to compose its prompt from:
/// `turn.persona()` (prompt, supplied guidance, expression facts), `turn.pins()`, `turn.recall()` and
/// `turn.context()` (digest, packet, history, facts, runtime). The order and the joins
/// are hers, in `abilities/turn.js`.
public struct TurnReach: Sendable, Equatable {
    public internal(set) var persona = ""
    public internal(set) var guidance = ""
    /// Null for an internal part thought: no persona or expression policy is injected.
    public internal(set) var expression: JSONValue = .null
    public internal(set) var pins: [String] = []
    public internal(set) var recall = ""
    public internal(set) var digest = ""
    public internal(set) var packet = ""
    public internal(set) var history = ""
    /// The facts of the moment, each already trimmed and non-empty.
    public internal(set) var facts: [String] = []
    public internal(set) var runtime: JSONValue = .null
}

/// The context handed to the LLM for one turn. Its system prompt is what her
/// turn part composed from `turnReach` (`composing`).
public struct TurnContext: Sendable {
    public let surface: String
    /// Exact persona selected for this turn. This follows the turn into tool
    /// dispatch so explicit memory recall uses the same disclosure boundary
    /// as automatic Fluid Context projection.
    public let personaID: String?
    public let personaDocs: [String: String]
    /// Source revision captured before USER's per-turn memory-core projection.
    public let personaFingerprint: String
    /// Off-mode recall hits before rendering trims them; active turns use packet provenance.
    public let recalled: [MemoryRecallHit]
    public internal(set) var modelId: String
    public internal(set) var reasoningEffort: String
    /// Immutable route admitted from one checked provider-routing snapshot.
    /// Adapters still reread canonical routing for corruption/revocation, but
    /// a valid mid-turn preference change cannot splice generations.
    public let providerId: String?
    public let serviceTier: String?
    /// Names captured at context assembly, before schema filtering.
    public let toolsAvailable: [String]
    /// Current filtered offer; ProviderToolNameMap translates its names on the wire.
    /// Empty when the dispatcher only supplies names.
    public internal(set) var toolSchemas: [LLMToolSchema]
    public internal(set) var systemPrompt: String?
    public let userMessage: String
    /// When present, systemSegments.combined equals systemPrompt, joining nonempty segments with "\n\n".
    /// Segments place Anthropic's cache breakpoint after stable content; nil uses the unsplit prompt.
    public internal(set) var systemSegments: SystemPromptSegments?
    /// Per-turn DYNAMIC image content blocks for the CURRENT user message.
    /// CACHE INVARIANT: image blocks live ONLY on the in-flight user message —
    /// they MUST NEVER enter `systemPrompt`/`systemSegments` (would churn the
    /// cached prefix every turn) and MUST NOT be persisted/re-sent on later
    /// turns. Default `[]` keeps every existing TurnContext construction site
    /// byte-identical to pre-multimodal behavior.
    public let imageBlocks: [LLMContentBlock]
    /// Pins one immutable ContextFlow generation through the complete
    /// provider/tool loop. nil keeps the legacy/off path unchanged.
    public let fluidContextTurn: ContextPreparedTurn?
    /// SessionHistoryMessages replays bounded prior turns oldest first for byte-stable caching; other callers leave this empty.
    public internal(set) var historyMessages: [LLMMessage]
    /// v2Prefix: the per-turn volatile mass (packet, recall, digest, derived
    /// history blocks, clock/runtime, plan hint, capsule) AFTER it has been
    /// lifted out of `systemSegments.dynamic` — see `splittingVolatileBlock()`.
    /// nil until that split runs.
    public internal(set) var turnVolatileBlock: String?
    /// What the replayed-prefix window cursor did for this turn. Set by
    /// history assembly (resident or helper) from the shared cursor, so
    /// every downstream receipt reports the same decision instead of re-reading
    /// it from disk or guessing zero. nil on non-history callers.
    public internal(set) var historyWindowReceipt: HistoryWindowReceipt?
    /// Only metadata attached to user turns that the projection actually replays.
    package var replayedTurnContexts: [SentTurnContext] = []
    /// Cursor boundary and retained recollection identities, not turn-varying text.
    package var historyContextWindow = "0:"
    /// Frozen duration from the context preparation summary, absent if unmeasured.
    public var preparationMs: Int64?
    /// The memory records this context delivers (packet provenance, or the
    /// legacy lane's rendered rows). Their usage credit is written once the
    /// provider accepts the context, never at assembly.
    public internal(set) var usageCreditMemoryIDs: [String] = []
    var cognitiveRuntimeContext: String? = nil
    public internal(set) var turnReach: TurnReach
    /// Recall provenance for stamping: untrimmed Off-mode hits, then packet IDs,
    /// deduplicated and capped at 32. Delivery credit uses usageCreditMemoryIDs.
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
        historyWindowReceipt: HistoryWindowReceipt? = nil,
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
        self.historyWindowReceipt = historyWindowReceipt
        self.preparationMs = preparationMs
        self.turnReach = turnReach
    }

    /// The system her turn part named, and the tools it offered.
    func composing(_ system: SystemPromptSegments, tools: [String]?) -> TurnContext {
        var copy = self
        copy.systemSegments = system
        copy.systemPrompt = system.combined
        if let tools { copy.toolSchemas = toolSchemas.filter { tools.contains($0.name) } }
        return copy
    }

    /// Lift the full built block at the message-seeding boundary
    /// (the two lanes) after every dynamic contributor has appended.
    ///
    /// Before paragraph delta selection, `turnVolatileBlock` is
    /// literally the same string `systemSegments.dynamic` held, in the same
    /// order, byte for byte. All that moves is WHERE it is delivered: out of
    /// the churning tail of the system prompt into the current user turn,
    /// after replayed history. Seeding selects its keyframe/delta and stores
    /// the delivered bytes as metadata on that user row. `systemPrompt` is
    /// rebuilt from the emptied segments so the
    /// adapter-verified `systemPrompt == segments.combined` invariant still
    /// holds by construction.
    ///
    /// `trailingSection` is per-turn text the CALLER wants delivered with the
    /// volatile mass rather than inside the cached prefix — today the
    /// text-compat lane's "Also loaded this session:" catalog run. It lands as
    /// its own trailing section, AFTER everything `dynamic` already held (so
    /// after the capsule). Empty (the default) is byte-identical to the
    /// original single-argument behavior, including the "nothing to move"
    /// early return.
    ///
    /// Returns `self` unchanged when there are no segments or nothing volatile
    /// to move — the split is never a way to lose bytes.
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
                contextSource: context.fluidContextTurn == nil ? "legacy" : "fluid_context",
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
    /// Exact number of provider completions issued by this engine invocation.
    /// A default keeps non-loop/legacy construction source-compatible; owners
    /// that cannot prove the count leave it nil rather than inventing zero.
    public let providerCallCount: Int?
    /// Engine-owned terminal truth, independent of any nonempty fallback prose.
    /// Legacy paths that do not report this evidence leave it unknown.
    public let completionState: CompletionState?
    public let terminalReason: TerminalReason?
    public let loopCounters: LoopCounters?
    /// Memory recording and private work released by the saved answer.
    public internal(set) var afterReply: AfterReply?
    /// How many LEADING characters of `reply` are working commentary — the
    /// narration the model spoke before each tool round — rather than the
    /// finished answer. The bytes are unchanged and every one of them is still
    /// persisted; this is only the boundary the transcript needs to fold the
    /// commentary away once the turn is done (third conversation pass, item 3).
    /// nil/0 for single-round turns, which have no commentary at all.
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
        if toolDispatches.contains(where: { ChatToolOutcome.isWaitingInteraction($0.result) }) { return .interactionRequired }
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

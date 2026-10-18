import ChatTurnContracts
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
    /// A provider stream failed mid-turn. `partial` carries the visible prose the
    /// user already watched render so the orchestration layer can persist it
    /// instead of silently dropping it (audit #5, 2026-06-14).
    case streamInterrupted(partial: String, underlying: Error)
    /// 2026-07-21 audit fix: a USER STOP mid-stream. Same partial-carry as
    /// streamInterrupted but the orchestration layer persists it with
    /// cancelled:true and rethrows CancellationError (cancel is not a
    /// failure); previously the structured lanes discarded the visible
    /// partial entirely on cancel while text-compat persisted it.
    case streamCancelled(partial: String, underlying: Error)
    /// Her turn part failed with no clean version left to swap in.
    case turnPartFailed(String)
    /// No helper can start to run her turn part, and waiting will not change that.
    case turnHelperUnavailable(String)

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
            return "My turn part could not run this turn: \(why) The turn part that ships with the app could not run it either; reinstall NativeAgent."
        case .turnHelperUnavailable(let why):
            return "My turn could not start its helper: \(why) Reinstall NativeAgent so its helper and sandbox profile are intact, then send again."
        }
    }
}

/// Bounded, payload-free result of the memory-promotion side channel.
public struct MemoryPromotionTelemetry: Sendable, Equatable {
    public let stagedProposalCount: Int64
    /// The moment pass's one-word outcome (see AdaptiveMemoryObservation).
    public var momentOutcome: String = "unreported"
    public var savedCorrectionCount: Int = 0
    public var pendingCorrectionCount: Int = 0
    public var failedCorrectionCount: Int = 0
    /// Phase 5A novelty gate: why the after-turn memory call was skipped.
    public var noveltySkipReason: String?
    public var failure: AfterTurnMemoryFailure?
    public var interpretationFailure: AfterTurnInterpretationFailure? { failure?.interpretationFailure }
    public let semanticStatus: MemorySemanticExtractionStatus
    public let semanticCandidateCount: Int64
    public let candidateCount: Int64

    public init(stagedProposalCount: Int, semanticStatus: MemorySemanticExtractionStatus = .unreported,
                semanticCandidateCount: Int = 0, candidateCount: Int = 0) {
        self.stagedProposalCount = Int64(max(0, stagedProposalCount))
        self.semanticStatus = semanticStatus
        self.semanticCandidateCount = Int64(max(0, semanticCandidateCount))
        self.candidateCount = Int64(max(0, candidateCount))
    }
}

public struct SharedAdaptiveMemoryPromoter: Sendable {
    public init() {}

    public func pendingMomentCount() async -> Int {
        await AdaptiveMemoryPromoter.shared.pendingMomentCount()
    }

    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String
    ) async -> MemoryPromotionTelemetry {
        let observation = await AdaptiveMemoryPromoter.shared.observeTurnWithReport(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId,
            surface: surface,
            standingAgentName: StandingBotContinuity.currentBot?.name,
            turnId: TurnTraceContext.turnId
        )
        var telemetry = MemoryPromotionTelemetry(
            stagedProposalCount: observation.proposals.count,
            semanticStatus: observation.extraction.semanticStatus,
            semanticCandidateCount: observation.extraction.semanticCandidateCount,
            candidateCount: observation.extraction.candidates.count
        )
        telemetry.momentOutcome = observation.momentOutcome
        telemetry.savedCorrectionCount = observation.savedCorrectionCount
        telemetry.pendingCorrectionCount = observation.pendingCorrectionCount
        telemetry.failedCorrectionCount = observation.failedCorrectionCount
        telemetry.noveltySkipReason = observation.noveltySkipReason
        telemetry.failure = observation.extraction.failure
        return telemetry
    }
}

// MARK: - Turn tool-evidence projection (sweep item 35)

/// Bounded projection of a turn's tool dispatches for the post-turn memory
/// promoter — "what she DID in a turn reaches memory".
///
/// Three properties, all load-bearing:
///
///  * **Bounded.** ≤ `maxDispatches` evidence lines, ≤ `maxLineChars` each,
///    selected head+tail so a long tool turn contributes its opening moves AND
///    its closing ones rather than only its opening.
///  * **Reused, not reinvented.** The per-result shape is
///    `SessionHistoryPromptRenderer.toolEvidenceProjection` — the exact head+tail
///    projection retained for durable fact evidence, which also
///    routes every byte through `ChatSecretRedactor`. Input values go through
///    the same redactor.
///  * **Quiet.** Only dispatches that SUCCEEDED (`exactResultClass ==
///    .succeeded`, which never reads a missing status as success) and carry a
///    stable fact shape (a path, a reverse-DNS identifier, a named file) are
///    eligible. Errors, timeouts, cancellations, pending/approval envelopes,
///    and pure reads of transient content are not.
///
/// NORTHSTAR clause 6: nothing here reaches her prompt. It is read AFTER the
/// reply, by the promoter, and everything it yields is an approval-gated
/// proposal.
enum TurnToolEvidenceProjection {
    static let maxDispatches = 6
    static let maxLineChars = 240
    private static let maxInputEntries = 2
    private static let maxInputValueChars = 80

    /// Tools whose success proves nothing durable: the reading is true for a
    /// moment and stale by the next turn. A path-shaped token inside one of
    /// these envelopes is incidental, not a fact worth proposing. (Recall and
    /// history tools are here for a second reason — promoting what memory
    /// returned would feed the store its own output.)
    private static let transientReaders: Set<String> = [
        "battery", "clock", "context_expand", "current_time", "date",
        "get_time", "get_weather", "list_notifications", "look", "observe",
        "ping", "random", "recall_memory", "roll", "screen", "screenshot",
        "search_chat_history", "search_memory", "memory_search",
        "session_search", "system_status", "time", "view", "weather",
    ]

    /// A path (`/a/b`), a reverse-DNS identifier (`com.apple.Notes`), or a
    /// named source file (`Auth.swift`). Anything else is prose.
    private static let stableFactShape = #"(?:/[A-Za-z0-9._~@%+-]+){2,}|\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+\b|\b[A-Za-z0-9_-]+\.(?:swift|ts|tsx|js|jsx|py|rb|rs|go|java|kt|json|md|ya?ml|toml|sh|zsh|[hmc]|cpp|plist|sql|txt|log|csv)\b"#

    /// Project one turn's dispatches. Empty in ⇒ empty out ⇒ the promoter sees
    /// exactly the prose-only turn it saw before this existed.
    static func project(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> [String] {
        guard !dispatches.isEmpty else { return [] }
        let lines = dedupe(dispatches.compactMap(evidenceLine(for:)))
        guard !lines.isEmpty else { return [] }
        let truncated = lines.count > maxDispatches
        guard truncated else { return lines }
        let head = maxDispatches - maxDispatches / 2
        return Array(lines.prefix(head)) + Array(lines.suffix(maxDispatches / 2))
    }

    /// The rendered evidence for one dispatch, or nil when it is not eligible.
    static func evidenceLine(
        for dispatch: TurnEngineResult.ToolDispatchRecord
    ) -> String? {
        guard ChatToolOutcome.exactResultClass(dispatch.result) == .succeeded else { return nil }
        // A successful enqueue is a receipt for the queue write, not evidence
        // that the requested effect happened at the supplied path or target.
        if case .object(let fields) = dispatch.result,
           case .string(let status)? = fields["status"],
           ["queued", "scheduled"].contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return nil
        }
        // An app call of a folded action is the tool it ran, over its args.
        let name = dispatch.ranCall.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !transientReaders.contains(name.lowercased()) else { return nil }

        let arguments = inputSummary(dispatch.ranCall.input)
        let result = SessionHistoryPromptRenderer.toolEvidenceProjection(resultText(dispatch.result))
        guard hasStableFactShape(arguments) || hasStableFactShape(result) else { return nil }

        var line = arguments.isEmpty ? "\(name) ok" : "\(name)(\(arguments)) ok"
        if !result.isEmpty { line += ": \(result)" }
        return hardCap(line, maxLineChars)
    }

    private static func dedupe(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// Scalar input arguments only, fact-shaped ones first, at most
    /// `maxInputEntries`. Nested objects/arrays are tool plumbing, not facts.
    private static func inputSummary(_ input: [String: JSONValue]) -> String {
        let scalars: [(String, String)] = input.keys.sorted().compactMap { key in
            guard let raw = scalarText(input[key]) else { return nil }
            let redacted = ChatSecretRedactor.redactText(raw)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !redacted.isEmpty else { return nil }
            return (key, String(redacted.prefix(maxInputValueChars)))
        }
        let ordered = scalars.enumerated().sorted { lhs, rhs in
            let l = hasStableFactShape(lhs.element.1)
            let r = hasStableFactShape(rhs.element.1)
            if l != r { return l }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return ordered.prefix(maxInputEntries)
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ", ")
    }

    private static func scalarText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return String(d)
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    private static func resultText(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        return (try? value.serialize(pretty: false)) ?? ""
    }

    private static func hasStableFactShape(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.range(of: stableFactShape, options: .regularExpression) != nil
    }

    private static func hardCap(_ text: String, _ maxCount: Int) -> String {
        guard text.count > maxCount else { return text }
        return String(text.prefix(max(0, maxCount - 3))) + "..."
    }
}

// MARK: - ToolDispatchClient

public typealias ToolDispatchClient = ChatTurnContracts.ToolDispatchClient

/// One immutable provider-routing generation admitted before a chat facade
/// chooses its execution branch. This is execution context only; the
/// ProviderRouting store remains the sole authority and adapters still use a
/// checked reread to detect corrupt/revoked authority.
struct TurnRouteAdmission: Sendable, Equatable {
    let routingSurface: String
    let modelId: String
    let reasoningEffort: String
    let providerId: String?
    let serviceTier: String?
}

// MARK: - TurnContext

/// What the stem gathers for her turn part to compose its prompt from:
/// `turn.persona()` (prompt, guidance), `turn.pins()`, `turn.recall()` and
/// `turn.context()` (digest, packet, history, facts). The order and the joins
/// are hers, in `abilities/turn.js`.
public struct TurnReach: Sendable, Equatable {
    public internal(set) var persona = ""
    public internal(set) var guidance = ""
    public internal(set) var pins: [String] = []
    public internal(set) var recall = ""
    public internal(set) var digest = ""
    public internal(set) var packet = ""
    public internal(set) var history = ""
    /// The facts of the moment, each already trimmed and non-empty.
    public internal(set) var facts: [String] = []
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
    public let recalled: [MemoryRecallHit]
    public internal(set) var modelId: String
    public internal(set) var reasoningEffort: String
    /// Immutable route admitted from one checked provider-routing snapshot.
    /// Adapters still reread canonical routing for corruption/revocation, but
    /// a valid mid-turn preference change cannot splice generations.
    public let providerId: String?
    public let serviceTier: String?
    public let toolsAvailable: [String]
    /// JSON-Schema descriptors for the same tools `toolsAvailable` lists by
    /// name. Threaded into `LLMClient.complete(...tools:)` so the model can
    /// emit tool calls. Empty when the dispatcher only knows names — the
    /// pre-W1 wire path (no tools embedded in the request body).
    public internal(set) var toolSchemas: [LLMToolSchema]
    public internal(set) var systemPrompt: String?
    public let userMessage: String
    /// U1 step 2b/3b (2026-06-10) — ADDITIVE stable/dynamic split of
    /// `systemPrompt` for provider prompt caching. When present:
    ///   INVARIANT: systemPrompt == systemSegments.combined
    ///              (== stable + "\n\n" + dynamic, empty segments collapse
    ///               the separator)
    /// `systemPrompt` stays the canonical model-visible content — every
    /// existing consumer keeps reading it unchanged. The segments are a
    /// layout hint the Anthropic adapters use to place the sys
    /// cache_control breakpoint at the end of the STABLE mass
    /// (persona + pins + the current lazy tool contract) instead of the end
    /// of the churning combined string.
    /// nil → legacy behavior everywhere.
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
    /// Request-scoped candidate derived from existing history. It is not model
    /// visible until the shared turn-plan seam confirms an ordinary chat turn.
    public internal(set) var naturalExpressionCue: String?
    /// v2Prefix (2026-09-01): prior turns replayed as REAL messages, oldest →
    /// newest, so a provider cache can match them byte-for-byte across turns.
    /// Empty on non-history callers. Produced by
    /// `SessionHistoryMessageProjection` from bounded transcript rows.
    public internal(set) var historyMessages: [LLMMessage]
    /// v2Prefix: the per-turn volatile mass (packet, recall, digest, derived
    /// history blocks, clock/runtime, plan hint, capsule) AFTER it has been
    /// lifted out of `systemSegments.dynamic` — see `splittingVolatileBlock()`.
    /// nil until that split runs.
    public internal(set) var turnVolatileBlock: String?
    /// What the replayed-prefix window cursor did for this turn. Set by
    /// `buildTurnContextWithHistory` — the one place that runs the cursor — so
    /// every downstream receipt reports the same decision instead of re-reading
    /// it from disk or guessing zero. nil on non-history callers.
    public internal(set) var historyWindowReceipt: HistoryWindowReceipt?
    /// Frozen duration from the context preparation summary, absent if unmeasured.
    public var preparationMs: Int64?
    public internal(set) var turnReach: TurnReach
    /// The memory record identities behind THIS turn — legacy recall hits
    /// plus the ContextFlow packet's resolved provenance. On active turns
    /// memory arrives in the packet and `recalled` is empty, so without the
    /// provenance half the recalled-memory stamp (and therefore next-turn
    /// memoryActivation) never fires. Legacy hits keep their order; packet
    /// provenance (already sorted) appends after; deduped, capped 32 to match
    /// the stamping bound downstream.
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
        naturalExpressionCue: String? = nil,
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
        self.naturalExpressionCue = naturalExpressionCue
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

    /// v2Prefix relocation, run ONCE per turn at the message-seeding boundary
    /// (the two lanes) after every dynamic contributor has appended.
    ///
    /// Model-visible content is UNCHANGED — the returned `turnVolatileBlock` is
    /// literally the same string `systemSegments.dynamic` held, in the same
    /// order, byte for byte. All that moves is WHERE it is delivered: out of
    /// the churning tail of the system prompt (which no provider cache can
    /// match twice) and into a message that sits AFTER the cached transcript
    /// prefix. `systemPrompt` is rebuilt from the emptied segments so the
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
            stableSuffix: segments.stableSuffix,
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
    public enum TerminalState: String, Sendable, Codable {
        case completed, interrupted, waiting, failed
    }

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
            case .cancelled, .providerInterrupted, .incomplete, .completionUnreported: return .interrupted
            case .providerFailed, .executionFailed: return .failed
            }
        }
    }

    public struct LoopCounters: Sendable {
        public internal(set) var providerAttemptCount = 0
        public internal(set) var failedProviderAttemptCount = 0
        /// First issued attempt of each loop iteration; retries are separate.
        public internal(set) var providerRoundCount = 0
        /// Reissued attempts, excluding recovery plans cancelled before dispatch.
        public internal(set) var providerRecoveryCount = 0
        public internal(set) var providerReplayCount = 0
        public internal(set) var providerContinuationCount = 0
        public internal(set) var contextOverflowRecoveryCount = 0
        public internal(set) var toolRoundCount = 0
        public internal(set) var roundsAfterToolFailureCount = 0
        public internal(set) var protocolViolationRoundCount = 0
        public internal(set) var emptyReplyRoundCount = 0
        public internal(set) var unfulfilledPromiseRoundCount = 0
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
    public let rawLLMResponse: String
    /// Exact number of provider completions issued by this engine invocation.
    /// A default keeps non-loop/legacy construction source-compatible; owners
    /// that cannot prove the count leave it nil rather than inventing zero.
    public let providerCallCount: Int?
    /// Exact provider-bound context facts captured by the engine. This is
    /// needed by paths (notably Anthropic text compatibility) whose caller does
    /// not own the final iteration's rebuilt TurnContext.
    public let terminalObservation: TerminalObservation?
    /// Engine-owned terminal truth, independent of any nonempty fallback prose.
    /// Legacy paths that do not report this evidence leave it unknown.
    public let completionState: CompletionState?
    public let terminalReason: TerminalReason?
    public let loopCounters: LoopCounters?
    /// THIS turn's claim on the deferred memory promotion it captured (Astra
    /// comb 3 review, finding 1, 2026-09-12). The engine used to hold ONE
    /// replaceable pending slot, so while turn A awaited its assistant append
    /// turn B could overwrite it: A then started B's promotion before B's row
    /// was durable, and A's promotion vanished. The ticket is the turn's own
    /// handle — `startDeferredMemoryPromotion(ticket:)` starts exactly the work
    /// this result's turn captured and nothing else. nil for paths that never
    /// deferred (they promote inline, or not at all).
    public let memoryPromotionTicket: UUID?
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
        rawLLMResponse: String,
        providerCallCount: Int? = nil,
        terminalObservation: TerminalObservation? = nil,
        completionState: CompletionState? = nil,
        memoryPromotionTicket: UUID? = nil,
        workingCommentaryCharacters: Int? = nil,
        terminalReason: TerminalReason? = nil,
        loopCounters: LoopCounters? = nil
    ) {
        self.reply = ChatRichContentParser.visibleText(reply)
        self.modelUsed = modelUsed
        self.recalledIds = recalledIds
        self.toolDispatches = toolDispatches
        self.elapsedMs = elapsedMs
        self.rawLLMResponse = rawLLMResponse
        self.providerCallCount = providerCallCount
        self.terminalObservation = terminalObservation
        self.completionState = completionState
        self.terminalReason = terminalReason
        self.loopCounters = loopCounters
        self.memoryPromotionTicket = memoryPromotionTicket
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
                  let rows = try? SwiftNativeApprovalInbox.loadApprovalRowsChecked(
                    at: dataRoot.appendingPathComponent("workflows/approvals/requests.json")
                  ) else { return .completionUnreported }
            let pendingIDs = Set(rows.compactMap(ApprovalRecord.init(json:))
                .filter { $0.status == "pending" }.map(\.id))
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
            toolDispatches: toolDispatches, elapsedMs: elapsedMs, rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount, terminalObservation: terminalObservation,
            completionState: completionState, memoryPromotionTicket: memoryPromotionTicket,
            workingCommentaryCharacters: workingCommentaryCharacters,
            terminalReason: reason, loopCounters: counters
        )
    }
}

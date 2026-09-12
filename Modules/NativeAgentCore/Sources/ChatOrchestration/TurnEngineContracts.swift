import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle
import Context
import CognitiveSubstrate

// MARK: - TurnEngineError

public enum TurnEngineError: Error, LocalizedError {
    case personaLoadFailed(underlying: Error)
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

    public var errorDescription: String? {
        switch self {
        case .personaLoadFailed(let e): return "persona load failed: \(e)"
        case .emptyMessage: return "userMessage was empty or whitespace-only"
        case .streamInterrupted(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .streamCancelled(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        }
    }
}

// MARK: - MemoryRecalling

public protocol MemoryRecalling: Sendable {
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit]
    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit]
    /// Bump use_count/last_used_at for memory records served into a turn by
    /// Fluid Context (task #42). On active ContextFlow turns the legacy recall
    /// lane — whose recordRecallHits call is the only other access-bump path —
    /// is skipped entirely, so packet-served memories otherwise read as
    /// "unused" to hygiene/eviction, starving exactly the hot rows. Must be a
    /// protocol REQUIREMENT (not extension-only) so existential dispatch
    /// reaches the production adapter (same trap as `matchesTombstone`).
    /// Non-throwing: implementations log failures; a dropped bump self-heals
    /// on any later serve.
    func recordServedContextHits(ids: [String]) async
}

public extension MemoryRecalling {
    /// Backward-compatible default for legacy/test recallers that do not own
    /// disclosure metadata. Production MemoryV2 adapters override this method
    /// so failover recall uses the same persona/surface policy as Fluid Context
    /// projection and the explicit `recall_memory` tool.
    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        try await recall(query, k: k)
    }

    /// Default no-op: legacy recallers and test fixtures track no access
    /// signals. The production V2 adapter overrides this with a real bump.
    func recordServedContextHits(ids: [String]) async {}
}

// MARK: - MemoryPromoting
//
// After-turn hook for adaptive memory promotion. The real implementation
// (AdaptiveMemoryPromoter — sister worker m5) inspects the user/assistant
// pair and may stage a promotion proposal. Until m5 lands, the protocol is
// here so the chat path can call into a no-op default and the seam is
// already wired. Optional on SwiftNativeChatOrchestrationClient — nil ⇒
// skip the call entirely.
public protocol MemoryPromoting: Sendable {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async

    /// Sweep item 35: the same turn, plus a BOUNDED projection of what she
    /// actually DID — the succeeded, fact-shaped tool dispatches, already
    /// head+tail projected and secret-redacted by
    /// `TurnToolEvidenceProjection`. The default implementation drops the
    /// evidence and calls the prose-only overload, so every existing
    /// conformer (narrow injectors, test fixtures) compiles and behaves
    /// EXACTLY as before.
    func observeTurn(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async
}

extension MemoryPromoting {
    public func observeTurn(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async {
        await observeTurn(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }
}

/// Bounded, payload-free result of the memory-promotion side channel.
///
/// `MemoryPromoting` stays intentionally source-compatible for narrow or
/// legacy injectors. Production promoters that can name their outcome adopt
/// this refinement so the turn receipt can distinguish "configured but no
/// candidate crossed the gate" from an unobservable promotion attempt.
public struct MemoryPromotionTelemetry: Sendable, Equatable {
    public let stagedProposalCount: Int64
    /// The moment pass's one-word outcome (see AdaptiveMemoryObservation).
    public var momentOutcome: String = "unreported"
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

/// Optional outcome reporting for the post-turn memory-promotion seam.
///
/// The telemetry contains only a count. Candidate text, proposal IDs, and
/// session content remain in the canonical memory store and never enter a
/// turn trace receipt.
public protocol MemoryPromotionTelemetryReporting: MemoryPromoting {
    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        sessionId: String
    ) async -> MemoryPromotionTelemetry

    /// Tool-evidence variant; default drops the evidence (see `MemoryPromoting`).
    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async -> MemoryPromotionTelemetry

    /// Surface-carrying variant (moments lane, 2026-09-02). A staged moment
    /// records WHERE it happened — chat, Telegram, a bridge — because "the
    /// night we shipped it over Telegram" is part of the moment. Default drops
    /// the surface exactly as the evidence default drops evidence, so every
    /// existing conformer compiles and behaves identically.
    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String,
        surface: String
    ) async -> MemoryPromotionTelemetry
}

extension MemoryPromotionTelemetryReporting {
    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }

    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String,
        surface: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId
        )
    }
}

/// How many moments are waiting on her review. Deliberately a COUNT and
/// nothing else: the per-turn nudge line names a number and a tool, and the
/// moments themselves stay in the store until she pulls them. Optional
/// refinement so a narrow or test promoter never has to answer.
public protocol MomentReviewQueueReporting: Sendable {
    func pendingMomentCount() async -> Int
}

public struct SharedAdaptiveMemoryPromoter: MemoryPromotionTelemetryReporting, MomentReviewQueueReporting {
    public init() {}

    public func pendingMomentCount() async -> Int {
        await AdaptiveMemoryPromoter.shared.pendingMomentCount()
    }

    public func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        _ = await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }

    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: [],
            sessionId: sessionId
        )
    }

    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId,
            surface: "chat"
        )
    }

    public func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String,
        surface: String
    ) async -> MemoryPromotionTelemetry {
        let observation = await AdaptiveMemoryPromoter.shared.observeTurnWithReport(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId,
            surface: surface
        )
        var telemetry = MemoryPromotionTelemetry(
            stagedProposalCount: observation.proposals.count,
            semanticStatus: observation.extraction.semanticStatus,
            semanticCandidateCount: observation.extraction.semanticCandidateCount,
            candidateCount: observation.extraction.candidates.count
                + observation.toolEvidenceCandidateCount
        )
        telemetry.momentOutcome = observation.momentOutcome
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
///    its closing ones rather than only its opening. A turn whose window was
///    not a contiguous verified run also carries one payload-free
///    `sequenceBreakMarker` line — see below.
///  * **Reused, not reinvented.** The per-result shape is
///    `SessionHistoryPromptRenderer.toolResultProjection` — the exact head+tail
///    projection SessionHistory already renders for later turns, which also
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

    /// Sequence-integrity marker (procedural lane, HIGH review finding
    /// 2026-09-01).
    ///
    /// The lines above are SUCCESS-ONLY by construction, which is exactly what
    /// the memory promoter wants and exactly what makes this array unsafe as
    /// proof that a PROCEDURE ran. `read ok, write ok, run_tests failed`
    /// projects to `read ok, write ok`; head+tail selection stitches an equally
    /// contiguous-looking run out of a ten-dispatch turn. A consumer asking
    /// "did these steps run start-to-finish, all verified" cannot tell either
    /// case from the real thing.
    ///
    /// So the projection SAYS so, in the one channel every call site already
    /// carries. When the turn contained a dispatch this projection could not
    /// read as a verified success, or when the window was truncated, one
    /// marker line is appended. Consumers that only want facts ignore it;
    /// consumers that need contiguity refuse the turn.
    ///
    /// Two properties keep it inert for the promoter: it opens with a
    /// character no tool name may contain, and it is SHORTER than
    /// `AdaptiveToolEvidence.minLineChars` (12), the floor below which the
    /// promoter drops a line before it can become a candidate. Keep it short.
    static let sequenceBreakMarker = "!seq-break"

    /// Project one turn's dispatches. Empty in ⇒ empty out ⇒ the promoter sees
    /// exactly the prose-only turn it saw before this existed.
    static func project(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> [String] {
        guard !dispatches.isEmpty else { return [] }
        let lines = dedupe(dispatches.compactMap(evidenceLine(for:)))
        guard !lines.isEmpty else { return [] }
        let truncated = lines.count > maxDispatches
        var selected = lines
        if truncated {
            let head = maxDispatches - maxDispatches / 2
            let tail = maxDispatches / 2
            selected = Array(lines.prefix(head)) + Array(lines.suffix(tail))
        }
        if truncated || hasNonSuccessDispatch(dispatches) {
            selected.append(sequenceBreakMarker)
        }
        return selected
    }

    /// True when the turn carries a dispatch this projection could not read as
    /// a verified success — failed, cancelled, timed out, pending, or simply
    /// unknown. `exactResultClass` never reads a missing status as success, so
    /// "not `.succeeded`" is the honest whole-turn question.
    static func hasNonSuccessDispatch(
        _ dispatches: [TurnEngineResult.ToolDispatchRecord]
    ) -> Bool {
        dispatches.contains { ChatToolOutcome.exactResultClass($0.result) != .succeeded }
    }

    /// The rendered evidence for one dispatch, or nil when it is not eligible.
    static func evidenceLine(
        for dispatch: TurnEngineResult.ToolDispatchRecord
    ) -> String? {
        guard ChatToolOutcome.exactResultClass(dispatch.result) == .succeeded else { return nil }
        let name = dispatch.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !transientReaders.contains(name.lowercased()) else { return nil }

        let arguments = inputSummary(dispatch.input)
        let result = SessionHistoryPromptRenderer.toolResultProjection(resultText(dispatch.result))
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

public protocol ToolDispatchClient: Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue
    func listAvailableTools() async throws -> [String]
    /// Tool-schema variant. Returns full JSON-Schema descriptors for the same
    /// tools `listAvailableTools()` exposes by name. Threaded through the
    /// LLMClient so the model can emit tool calls. Default implementation
    /// returns `[]` so dispatchers that only know names compile unchanged
    /// (the LLM then sees no tools — pre-tools behavior).
    func listAvailableToolSchemas() async throws -> [LLMToolSchema]
}

extension ToolDispatchClient {
    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

struct TurnContextSnapshot: Sendable {
    let providerPreferences: [String: SurfacePreference]
    let toolNames: [String]
    let toolSchemas: [LLMToolSchema]

    var toolSchemaParameterBytes: Int {
        toolSchemas.reduce(0) { $0 + $1.parametersJSON.count }
    }
}

/// A schema catalog already read for this turn before ContextFlow preparation.
///
/// `context_expand` is ALWAYS in this catalog (2026-09-01). It used to be
/// added or dropped per turn depending on whether that turn's packet happened
/// to carry expandable pointers — which meant the advertised contract, and
/// therefore the cached prompt prefix, changed shape for a reason the model
/// never asked about. It is in `alwaysOnCoreNames`; the floor is the floor.
/// When there is nothing to expand the tool simply says so at dispatch, which
/// is cheaper than rewriting the prefix.
public struct TurnToolSchemaCatalogSeed: Sendable {
    public let schemas: [LLMToolSchema]

    static let canonicalContextExpandSchema = LLMToolSchema(
        name: "context_expand",
        description: "Read one deeper context section offered for this turn. The atom id must come from the current context pointer list; expansion is read-only and pinned to this turn's immutable generation.",
        parametersJSON: (try? JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "atom_id": .object([
                    "type": .string("string"),
                    "description": .string("Atom id from the current turn's offered context pointers."),
                ]),
                "max_characters": .object([
                    "type": .string("integer"),
                    "description": .string("Optional bounded character limit."),
                ]),
            ]),
            "required": .array([.string("atom_id")]),
        ]).serializedData(pretty: false)) ?? Data("{}".utf8)
    )

    public init(schemas: [LLMToolSchema]) {
        guard !schemas.contains(where: { $0.name == "context_expand" }) else {
            self.schemas = schemas
            return
        }
        // Canonical built-in order places context_expand directly after
        // read_file. Retain that order so provider tool arrays and prompt
        // cache prefixes do not change merely because this path reused a
        // preload built before the packet existed.
        var seeded = schemas
        let insertion = seeded.firstIndex { $0.name == "read_file" }.map { $0 + 1 }
            ?? seeded.count
        seeded.insert(Self.canonicalContextExpandSchema, at: insertion)
        self.schemas = seeded
    }
}

/// Turn-owned quiet-hours preference bytes. The wrapper is intentionally
/// non-optional even when no window is configured, so a multi-iteration turn
/// can distinguish "captured absence" from "not captured yet" and avoid a
/// second preference-file read.
public struct TurnQuietHoursSnapshot: Sendable, Equatable {
    let window: TurnQuietHoursWindow?

    public init(window: TurnQuietHoursWindow?) {
        self.window = window
    }
}

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

/// The fully-assembled context handed to the LLM for one turn.
public struct TurnContext: Sendable {
    public let surface: String
    /// Exact persona selected for this turn. This follows the turn into tool
    /// dispatch so explicit memory recall uses the same disclosure boundary
    /// as automatic Fluid Context projection.
    public let personaID: String?
    public let personaDocs: [String: String]
    public let recalled: [MemoryRecallHit]
    public let modelId: String
    public let reasoningEffort: String
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
    public let toolSchemas: [LLMToolSchema]
    public let systemPrompt: String?
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
    public let systemSegments: SystemPromptSegments?
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
    public let naturalExpressionCue: String?
    /// v2Prefix (2026-09-01): prior turns replayed as REAL messages, oldest →
    /// newest, so a provider cache can match them byte-for-byte across turns.
    /// Empty on `.v1Legacy` and on every non-history caller — where it is
    /// empty, this context is byte-identical to the pre-v2 shape.
    /// Produced by `SessionHistoryMessageProjection` from EXACTLY the rows the
    /// v1 history block admitted.
    public let historyMessages: [LLMMessage]
    /// v2Prefix: the per-turn volatile mass (packet, recall, digest, derived
    /// history blocks, clock/runtime, plan hint, capsule) AFTER it has been
    /// lifted out of `systemSegments.dynamic` — see `splittingVolatileBlock()`.
    /// nil until that split runs; on `.v1Legacy` it stays nil forever and the
    /// same bytes remain in `dynamic` exactly as before.
    public let turnVolatileBlock: String?
    /// What the replayed-prefix window cursor did for this turn. Set by
    /// `buildTurnContextWithHistory` — the one place that runs the cursor — so
    /// every downstream receipt reports the same decision instead of re-reading
    /// it from disk or guessing zero. nil on `.v1Legacy` and every non-history
    /// caller.
    public let historyWindowReceipt: HistoryWindowReceipt?
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
        recalled: [MemoryRecallHit],
        modelId: String,
        reasoningEffort: String,
        providerId: String? = nil,
        serviceTier: String? = nil,
        toolsAvailable: [String],
        systemPrompt: String?,
        userMessage: String,
        toolSchemas: [LLMToolSchema] = [],
        systemSegments: SystemPromptSegments? = nil,
        imageBlocks: [LLMContentBlock] = [],
        fluidContextTurn: ContextPreparedTurn? = nil,
        naturalExpressionCue: String? = nil,
        historyMessages: [LLMMessage] = [],
        turnVolatileBlock: String? = nil,
        historyWindowReceipt: HistoryWindowReceipt? = nil
    ) {
        self.surface = surface
        self.personaID = personaID
        self.personaDocs = personaDocs
        self.recalled = recalled
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.providerId = providerId
        self.serviceTier = serviceTier
        self.toolsAvailable = toolsAvailable
        self.toolSchemas = toolSchemas
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.systemSegments = systemSegments
        self.imageBlocks = imageBlocks
        self.fluidContextTurn = fluidContextTurn
        self.naturalExpressionCue = naturalExpressionCue
        self.historyMessages = historyMessages
        self.turnVolatileBlock = turnVolatileBlock
        self.historyWindowReceipt = historyWindowReceipt
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
        return TurnContext(
            surface: surface,
            personaID: personaID,
            personaDocs: personaDocs,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            providerId: providerId,
            serviceTier: serviceTier,
            toolsAvailable: toolsAvailable,
            systemPrompt: lifted.combined,
            userMessage: userMessage,
            toolSchemas: toolSchemas,
            systemSegments: lifted,
            imageBlocks: imageBlocks,
            fluidContextTurn: fluidContextTurn,
            naturalExpressionCue: naturalExpressionCue,
            historyMessages: historyMessages,
            turnVolatileBlock: volatileBlock,
            historyWindowReceipt: historyWindowReceipt
        )
    }
}

// MARK: - TurnEngineResult

public struct TurnEngineResult: Sendable {
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

    public struct ToolDispatchRecord: Sendable {
        /// Provider-issued tool-use identity when the transport supplied one.
        /// Outcome Tissue hashes this before persistence; nil remains an
        /// explicit sequence-only observation for legacy/direct dispatches.
        public let id: String?
        public let name: String
        public let input: [String: JSONValue]
        public let result: JSONValue

        public init(
            id: String? = nil,
            name: String,
            input: [String: JSONValue],
            result: JSONValue
        ) {
            self.id = id
            self.name = name
            self.input = input
            self.result = result
        }
    }

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
    /// THIS turn's claim on the deferred memory promotion it captured (Astra
    /// comb 3 review, finding 1, 2026-09-12). The engine used to hold ONE
    /// replaceable pending slot, so while turn A awaited its assistant append
    /// turn B could overwrite it: A then started B's promotion before B's row
    /// was durable, and A's promotion vanished. The ticket is the turn's own
    /// handle — `startDeferredMemoryPromotion(ticket:)` starts exactly the work
    /// this result's turn captured and nothing else. nil for paths that never
    /// deferred (they promote inline, or not at all).
    public let memoryPromotionTicket: UUID?

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
        memoryPromotionTicket: UUID? = nil
    ) {
        self.reply = reply
        self.modelUsed = modelUsed
        self.recalledIds = recalledIds
        self.toolDispatches = toolDispatches
        self.elapsedMs = elapsedMs
        self.rawLLMResponse = rawLLMResponse
        self.providerCallCount = providerCallCount
        self.terminalObservation = terminalObservation
        self.completionState = completionState
        self.memoryPromotionTicket = memoryPromotionTicket
    }
}

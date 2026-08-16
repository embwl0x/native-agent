import Foundation
import ProviderRouting

/// SINGLE SOURCE OF TRUTH for every prompt-assembly character budget.
///
/// Sweep R4 lane-A finding #2: every context budget in the assembler was a
/// hardcoded literal — history 22k chars, memory 5 rows × 1,200, capsule 4k,
/// ranked packet 6k/24k — while `ProviderRouting.contextLength(forModel:)`
/// already knew the real window (kimi-k3 = 1,048,576 tokens) and had NO
/// prompt-assembly caller. Net effect: under 1% window utilization on a
/// million-token model.
///
/// This type turns those literals into a FUNCTION of the model's window.
/// Two hard rules govern it:
///
///  1. **The literals are the FLOOR.** No resolved budget is ever smaller than
///     what shipped before this policy existed. Scaling can only add room.
///  2. **Small windows are byte-identical.** A window at or below
///     `floorWindowTokens` — and any turn where the model is unknown or not
///     resolved at all — short-circuits to the floor table with NO arithmetic,
///     so speed-must-be-free holds for small-window models: their assembled
///     prompt is unchanged, byte for byte. `ContextBudgetPolicyTests` pins it.
///
/// There is NO post-assembly provider input clamp on the adapter paths —
/// safety comes from the ceiling-sum invariant above the tuning constants:
/// the worst-case derived ask provably fits the smallest catalog-gated
/// window. This policy decides how much we ASK for, and its ceilings are
/// sized so the ask can never exceed what any gate-passing model accepts.
public enum ContextBudgetPolicy {

    // MARK: - Tuning constants (every number in this file, nowhere else)

    /// Rough characters-per-token for English prose + code. Deliberately on the
    /// low side of the usual 3.5–4.0 range: undercounting chars-per-token means
    /// we ask for FEWER characters than the window can hold, which is the safe
    /// direction to be wrong in.
    static let charactersPerToken = 3.2

    /// Share of the window that history + memory + capsule may claim between
    /// them. The remaining ~75% covers the persona/system blocks, tool schemas,
    /// the ranked packet, the user message, and — the reason this is not 50% —
    /// the model's own reply plus reasoning tokens.
    static let combinedUtilizationFraction = 0.25

    /// At or below this window, budgets are EXACTLY the pre-policy literals.
    /// 32,768 is the largest window where today's ~32k characters of assembled
    /// context is already a substantial share of the budget, so there is
    /// nothing to win by scaling and everything to lose by regressing a small
    /// model's prompt.
    static let floorWindowTokens = 32_768

    /// The chat/mac floor total as RENDERED: history 22,000 + memory
    /// 5×(1,200 + per-row markup) + capsule 4,000. Used as the denominator that
    /// turns "characters this window can afford" into a scale factor applied to
    /// every surface's own floors, so telegram and iOS scale from THEIR floors
    /// and keep their relative size.
    ///
    /// The markup term is not cosmetic: `memoryBlockChars` bounds rendered
    /// rows, so leaving it out of the denominator makes the scale factor
    /// slightly too generous and `governedTotalChars` overshoots the allowance
    /// on mid-size windows. `derivedTotalNeverExceedsUtilizationFraction`
    /// caught exactly that.
    static let referenceFloorTotalCharacters =
        22_000 + (5 * (1_200 + memoryRowOverheadChars)) + 4_000

    /// Absolute ceilings. Past these, more context stops buying attention and
    /// — the binding constraint — their SUM must provably fit the SMALLEST
    /// window any catalog-gated model can actually have. The derive regime is
    /// only reachable through FirstPartyModelCatalog membership, whose
    /// smallest window is 128k tokens; a stale or over-optimistic catalog row
    /// claiming 1M for what is really a 128k account limit must still produce
    /// a prompt the provider accepts, because NO post-assembly input clamp
    /// exists on the adapter paths (gpt-5.5 review 2026-08-06, blocking).
    /// Invariant, enforced by worstCaseDerivedFitsCatalogMinimum test:
    ///   (history + memory + relevant + capsule + packetExpanded ceilings +
    ///    per-row slack) / 3.2 chars-per-token + output reserve
    ///   ≤ 60% of the 128k catalog minimum.
    /// starts buying latency and cost.
    static let maximumHistoryCharacters = 96_000
    static let maximumMemoryBlockCharacters = 24_000
    static let maximumRelevantCharacters = 24_000
    static let maximumCapsuleCharacters = 8_000
    static let maximumPacketCharacters = 32_000
    static let maximumPacketExpandedCharacters = 48_000
    static let maximumPacketPostMandatoryReserve = 40_000

    /// Per-ROW caps (one user turn, one memory row, one tool receipt) scale far
    /// more gently than the aggregate: a bigger window means we can afford MORE
    /// rows, not that any single row suddenly deserves 30× the space. 4× is
    /// enough to stop clipping a long message while keeping one pathological
    /// row from eating the block.
    static let maximumRowScale = 4.0

    /// Recall breadth. Doubles once the window is genuinely large; a 200k model
    /// keeps today's 5 (the extra rows are worth more on a 1M window where the
    /// memory block cap can actually carry them).
    /// Non-content characters a rendered memory row carries: the `- ` bullet,
    /// the newline, and the `[2026-07-14, preference]` provenance marker. The
    /// per-row content cap is sized net of this so `rowLimit` FULL rows
    /// actually fit inside `maximumMemoryBlockCharacters` — without it the last
    /// row is dropped by the aggregate bound and the doubled recall breadth
    /// quietly buys 9 rows instead of 10.
    static let memoryRowOverheadChars = 64

    static let baseRecallRowLimit = 5
    static let wideRecallRowLimit = 10
    static let wideRecallWindowTokens = 200_000

    // MARK: - Floors (today's literals, verbatim)

    /// The pre-policy budget table. Every value here shipped before this file
    /// existed and is reproduced EXACTLY; the floor regime returns these
    /// structs untouched.
    public struct Floors: Sendable {
        public let historyChars: Int
        public let userCap: Int
        public let assistantCap: Int
        public let systemCap: Int
        public let compactionSummaryCap: Int
        public let toolCap: Int
        public let continuityCap: Int
        public let relevantChars: Int
        public let relevantItemCap: Int
    }

    /// Surface floors lifted verbatim from `SessionHistoryPromptRenderer
    /// .budget(for:)` as it stood at sweep R4 W2.
    static func floors(forSurface surface: String) -> Floors {
        switch surface.lowercased() {
        case "telegram":
            return Floors(
                historyChars: 9_000,
                userCap: 900,
                assistantCap: 1_100,
                systemCap: 700,
                compactionSummaryCap: 4_000,
                toolCap: 220,
                continuityCap: 2_200,
                relevantChars: 1_600,
                relevantItemCap: 420
            )
        case "ios", "mobile", "iphone", "icloud":
            return Floors(
                historyChars: 13_000,
                userCap: 1_100,
                assistantCap: 1_400,
                systemCap: 900,
                compactionSummaryCap: 6_000,
                toolCap: 260,
                continuityCap: 2_600,
                relevantChars: 2_000,
                relevantItemCap: 520
            )
        case "chat", "mac", "default":
            return Floors(
                historyChars: 22_000,
                userCap: 1_800,
                assistantCap: 2_200,
                systemCap: 1_200,
                // Sized to ChatCompactionDistiller.maxSummaryChars — on
                // chat/mac the 22,000-char history budget can carry a full
                // recollection AND ~10k of live turns.
                compactionSummaryCap: ChatCompactionDistiller.maxSummaryChars,
                toolCap: 320,
                continuityCap: 3_200,
                relevantChars: 2_400,
                relevantItemCap: 650
            )
        default:
            return Floors(
                historyChars: 11_000,
                userCap: 1_000,
                assistantCap: 1_200,
                systemCap: 800,
                compactionSummaryCap: 5_000,
                toolCap: 240,
                continuityCap: 2_200,
                relevantChars: 1_700,
                relevantItemCap: 460
            )
        }
    }

    /// Surface-independent floors (memory recall, capsule, ranked packet).
    /// These were literals at their own call sites, not in the history table.
    static let floorMemoryRowChars = 1_200          // TurnEngine.recalledMemoryRowCharCap
    static let floorRecallRowLimit = 5              // TurnEngine.recalledMemoryRowLimit / recall(k:)
    static let floorCapsuleChars = 4_000            // cognitiveTurnProjectionRequest
    static let floorPacketChars = 6_000             // ContextTurnRequest.characterBudget
    static let floorPacketExpandedChars = 24_000    // ContextTurnRequest.maximumCharacterBudget
    static let floorPacketPostMandatoryReserve = 4_000

    // MARK: - Resolved budget

    /// The budget for one turn on one surface. Field names for the history
    /// block match the renderer's former private `Budget` struct exactly, so
    /// the renderer typealiases straight onto this type.
    public struct Resolved: Sendable {
        // History renderer
        public let historyChars: Int
        public let userCap: Int
        public let assistantCap: Int
        public let systemCap: Int
        public let compactionSummaryCap: Int
        public let toolCap: Int
        public let continuityCap: Int
        public let relevantChars: Int
        public let relevantItemCap: Int

        // Memory recall block
        public let recallRowLimit: Int
        public let memoryRowChars: Int
        public let memoryBlockChars: Int

        // Cognitive capsule
        public let capsuleChars: Int

        // Fluid-context ranked packet
        public let packetChars: Int
        public let packetExpandedChars: Int
        public let packetPostMandatoryReserve: Int

        // Provenance (trace)
        public let windowTokens: Int?
        public let isDerived: Bool

        /// The three blocks the utilization fraction governs. Bounded by
        /// `derivedCharacterAllowance` whenever `isDerived` is true.
        public var governedTotalChars: Int {
            historyChars + memoryBlockChars + capsuleChars
        }
    }

    /// Characters the utilization fraction allows for a given window. Exposed
    /// so the eval harness can assert the bound rather than restate the math.
    public static func derivedCharacterAllowance(windowTokens: Int) -> Int {
        Int(Double(windowTokens) * charactersPerToken * combinedUtilizationFraction)
    }

    /// Window for a model id, or nil when the id is blank or NOT a model this
    /// build knows. `ProviderRouting.contextLength(forModel:)` answers 128,000
    /// for anything unrecognized — a deliberately pessimistic gauge default,
    /// not a measurement — so an unknown id must land in the floor regime
    /// rather than be scaled against a guess.
    public static func windowTokens(
        forModel modelID: String?,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int? {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return ProviderRouting.verifiedContextLength(
            forModel: raw, providerID: providerID, dataRoot: dataRoot
        )
    }

    // MARK: - Resolution

    /// The one entry point. `windowTokens == nil` (unknown/unresolved model)
    /// or a window at/below `floorWindowTokens` returns the floor table with no
    /// arithmetic applied.
    public static func resolve(windowTokens: Int?, surface: String) -> Resolved {
        let floors = floors(forSurface: surface)
        guard let windowTokens, windowTokens > floorWindowTokens else {
            return floorBudget(floors: floors, windowTokens: windowTokens)
        }

        let allowance = derivedCharacterAllowance(windowTokens: windowTokens)
        // Scale is relative to the chat/mac floor total, so every surface grows
        // proportionally from its OWN floor and never below it.
        let scale = max(1.0, Double(allowance) / Double(referenceFloorTotalCharacters))
        let rowScale = min(scale, maximumRowScale)

        let recallRowLimit = windowTokens > wideRecallWindowTokens
            ? wideRecallRowLimit
            : baseRecallRowLimit
        // Row size is bounded twice: by the gentle row scale, and by its share
        // of the memory block ceiling once the row COUNT has doubled.
        let memoryRowChars = min(
            grow(floorMemoryRowChars, rowScale),
            max(
                floorMemoryRowChars,
                (maximumMemoryBlockCharacters / recallRowLimit) - memoryRowOverheadChars
            )
        )

        return Resolved(
            historyChars: min(maximumHistoryCharacters, grow(floors.historyChars, scale)),
            userCap: grow(floors.userCap, rowScale),
            assistantCap: grow(floors.assistantCap, rowScale),
            systemCap: grow(floors.systemCap, rowScale),
            // The distiller never writes more than maxSummaryChars, so more
            // room than that buys literally nothing.
            compactionSummaryCap: min(
                ChatCompactionDistiller.maxSummaryChars,
                grow(floors.compactionSummaryCap, rowScale)
            ),
            toolCap: grow(floors.toolCap, rowScale),
            continuityCap: grow(floors.continuityCap, rowScale),
            relevantChars: min(maximumRelevantCharacters, grow(floors.relevantChars, scale)),
            relevantItemCap: grow(floors.relevantItemCap, rowScale),
            recallRowLimit: recallRowLimit,
            memoryRowChars: memoryRowChars,
            // The aggregate bound is measured against RENDERED rows, so it
            // must account for the same per-row markup the row cap was sized
            // net of. Bounding `limit × content` instead would make the last
            // full row unrenderable by construction.
            memoryBlockChars: min(
                maximumMemoryBlockCharacters,
                recallRowLimit * (memoryRowChars + memoryRowOverheadChars)
            ),
            capsuleChars: min(maximumCapsuleCharacters, grow(floorCapsuleChars, scale)),
            packetChars: min(maximumPacketCharacters, grow(floorPacketChars, scale)),
            packetExpandedChars: min(
                maximumPacketExpandedCharacters,
                grow(floorPacketExpandedChars, scale)
            ),
            packetPostMandatoryReserve: min(
                maximumPacketPostMandatoryReserve,
                grow(floorPacketPostMandatoryReserve, scale)
            ),
            windowTokens: windowTokens,
            isDerived: true
        )
    }

    /// Convenience: resolve straight from a model id.
    public static func resolve(
        model: String?,
        providerID: String? = nil,
        dataRoot: URL? = nil,
        surface: String
    ) -> Resolved {
        resolve(
            windowTokens: windowTokens(
                forModel: model, providerID: providerID, dataRoot: dataRoot
            ),
            surface: surface
        )
    }

    // MARK: - Internals

    /// Floor regime: the literal table, no multiplication anywhere. `windowTokens`
    /// is carried through for the trace even though it did not change anything.
    private static func floorBudget(floors: Floors, windowTokens: Int?) -> Resolved {
        Resolved(
            historyChars: floors.historyChars,
            userCap: floors.userCap,
            assistantCap: floors.assistantCap,
            systemCap: floors.systemCap,
            compactionSummaryCap: floors.compactionSummaryCap,
            toolCap: floors.toolCap,
            continuityCap: floors.continuityCap,
            relevantChars: floors.relevantChars,
            relevantItemCap: floors.relevantItemCap,
            recallRowLimit: floorRecallRowLimit,
            memoryRowChars: floorMemoryRowChars,
            memoryBlockChars: floorRecallRowLimit * floorMemoryRowChars,
            capsuleChars: floorCapsuleChars,
            packetChars: floorPacketChars,
            packetExpandedChars: floorPacketExpandedChars,
            packetPostMandatoryReserve: floorPacketPostMandatoryReserve,
            windowTokens: windowTokens,
            isDerived: false
        )
    }

    /// TRUNCATING scale — never rounds up. Guarantees the summed derived
    /// budgets stay at or under `derivedCharacterAllowance` (the eval harness
    /// asserts exactly that), and guarantees `grow(x, 1.0) == x` for the
    /// byte-identical floor case.
    private static func grow(_ value: Int, _ scale: Double) -> Int {
        max(value, Int(Double(value) * scale))
    }
}

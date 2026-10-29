import Foundation
import NativeAgentCore
import ProviderRouting
import os
// Blueprint: | `ContextBudgetPolicy.swift` | Shared model-input budgets for every door; `compactionHistoryCharacters`, `floors`; derived budget reuse by exact effective window after current model/catalog resolution |

/// Prompt-assembly budgets scale with the effective context window and never undercut floors.
public enum ContextBudgetPolicy {

    // MARK: - Tuning constants (every number in this file, nowhere else)

    /// Rough characters-per-token for English prose + code. Deliberately on the
    /// low side of the usual 3.5–4.0 range: undercounting chars-per-token means
    /// we ask for FEWER characters than the window can hold, which is the safe
    /// direction to be wrong in.
    package static let charactersPerToken = 3.2

    /// Transcript-size approximation when no tokenizer counts are available.
    /// Shared by transcript status, aging and compaction; model spelling is not tokenizer evidence.
    /// The 3.2 prompt-budget factor above is a separate, tighter safety margin.
    package static let transcriptCharactersPerToken = 3.5

    /// Window fraction used to scale the derived block budgets.
    static let combinedUtilizationFraction = 0.25

    /// At or below this window, budgets are EXACTLY the pre-policy literals.
    /// 32,768 is the largest window where today's ~32k characters of assembled
    /// context is already a substantial share of the budget, so there is
    /// nothing to win by scaling and everything to lose by regressing a small
    /// model's prompt.
    static let floorWindowTokens = 32_768

    /// Rendered history + memory (including row markup) + capsule floors:
    /// the denominator for the derived character allowance's scale factor.
    static let referenceFloorTotalCharacters =
        22_000 + (5 * (1_200 + memoryRowOverheadChars)) + 4_000

    /// Ceiling of the scaled-history term; the separate history rule can raise the final budget.
    static let maximumHistoryCharacters = 96_000

    /// Reserve tokens for persona, tools, other context, one tool round, a working note and output.
    static let requestReserveTokens = 128_000
    /// The whole request, including output, stays inside this share of the model window.
    static let requestWindowFraction = 0.90

    /// Separate history rule: effective-window room limited by the model's request share after reserve.
    static func compactionHistoryCharacters(windowTokens: Int) -> Int {
        let modelFloor = Double(windowTokens) / ChatSessionAutocompactionConfig.maximumContextWindowFraction
        let room = Int(modelFloor * requestWindowFraction) - requestReserveTokens
        return Int(Double(min(windowTokens, room)) * charactersPerToken)
    }

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

    /// Per-row content leaves room for the bullet, newline and provenance marker inside the block cap.
    static let memoryRowOverheadChars = 64

    static let baseRecallRowLimit = 5
    package static let wideRecallRowLimit = 12
    /// Wide recall starts at 60% of a 200k-token model window.
    static let wideRecallWindowTokens = 120_000

    // MARK: - Packet atom rendering (NORTHSTAR clause 6: reach, not weight)

    /// Long atoms become leads with expansion pointers; this threshold is window-independent.
    package static let packetAtomExpandThresholdChars = 400

    // MARK: - Floors (today's literals, verbatim)

    /// The pre-policy budget table. Every value here shipped before this file
    /// existed and is reproduced EXACTLY; the floor regime returns these
    /// structs untouched.
    public struct Floors: Sendable {
        public let historyChars: Int
        public let userCap: Int
        public let systemCap: Int
        public let compactionSummaryCap: Int
        public let relevantChars: Int
        public let relevantItemCap: Int
    }

    /// Every door assembles the same model input; delivery owns reply limits.
    static let floors = Floors(
        historyChars: 22_000,
        userCap: 1_800,
        systemCap: 1_200,
        compactionSummaryCap: ChatCompactionDistiller.maxSummaryChars,
        relevantChars: 2_400,
        relevantItemCap: 650
    )

    /// Surface-independent floors (memory recall, capsule, ranked packet).
    /// These were literals at their own call sites, not in the history table.
    // Their product is also the person picture's bound
    // (`UserMDAutogenMarkers.promptByteCap`, a base target that cannot read
    // these): change them together.
    static let floorMemoryRowChars = 1_200          // TurnEngine.recalledMemoryRowCharCap
    static let floorRecallRowLimit = 5              // TurnEngine.recalledMemoryRowLimit / recall(k:)
    static let floorCapsuleChars = 4_000            // Cognitive capsule request
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
        public let systemCap: Int
        public let compactionSummaryCap: Int
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
    }

    /// Scaling input for derived budgets, not a cap on their sum.
    public static func derivedCharacterAllowance(windowTokens: Int) -> Int {
        Int(Double(windowTokens) * charactersPerToken * combinedUtilizationFraction)
    }

    /// Use the effective window; unresolved model or route windows return nil and use floor budgets.
    public static func windowTokens(
        forModel modelID: String?,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int? {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return ChatSessionAutocompactionConfig.productionDefault().effectiveWindowTokens(
            forModel: raw, providerID: providerID, dataRoot: dataRoot
        )
    }

    // MARK: - Resolution

    /// Only the derived pure projection is retained, keyed by the exact effective
    /// window. Model/catalog and saved-window authority are still resolved on
    /// every model-based call before reaching this cache; no route is frozen.
    private static let resolvedGeneration = OSAllocatedUnfairLock<Resolved?>(initialState: nil)

    /// The one entry point. `windowTokens == nil` (unknown/unresolved model)
    /// or a window at/below `floorWindowTokens` returns the floor table with no
    /// arithmetic applied.
    public static func resolve(windowTokens: Int?) -> Resolved {
        guard let windowTokens, windowTokens > floorWindowTokens else {
            return floorBudget(floors: floors, windowTokens: windowTokens)
        }
        return resolvedGeneration.withLock { generation in
            if let generation, generation.windowTokens == windowTokens { return generation }
            let resolved = deriveBudget(windowTokens: windowTokens)
            generation = resolved
            return resolved
        }
    }

    private static func deriveBudget(windowTokens: Int) -> Resolved {
        let allowance = derivedCharacterAllowance(windowTokens: windowTokens)
        // Scale from the shared floor total and never below it.
        let scale = max(1.0, Double(allowance) / Double(referenceFloorTotalCharacters))
        let rowScale = min(scale, maximumRowScale)

        // Wide recall includes the threshold itself.
        let recallRowLimit = windowTokens >= wideRecallWindowTokens
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
            // Final history takes the larger of scaled history and the effective-window/request-reserve rule.
            historyChars: max(
                min(maximumHistoryCharacters, grow(floors.historyChars, scale)),
                compactionHistoryCharacters(windowTokens: windowTokens)
            ),
            userCap: grow(floors.userCap, rowScale),
            systemCap: grow(floors.systemCap, rowScale),
            // The distiller never writes more than maxSummaryChars, so more
            // room than that buys literally nothing.
            // The whole recollection renders; per-surface floors would cut it.
            compactionSummaryCap: ChatCompactionDistiller.maxSummaryChars,
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
        dataRoot: URL? = nil
    ) -> Resolved {
        resolve(
            windowTokens: windowTokens(
                forModel: model, providerID: providerID, dataRoot: dataRoot
            )
        )
    }

    // MARK: - Internals

    /// Floor regime: the literal table, no multiplication anywhere. `windowTokens`
    /// is carried through for the trace even though it did not change anything.
    private static func floorBudget(floors: Floors, windowTokens: Int?) -> Resolved {
        Resolved(
            historyChars: floors.historyChars,
            userCap: floors.userCap,
            systemCap: floors.systemCap,
            compactionSummaryCap: floors.compactionSummaryCap,
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

    /// Truncate scaled values without undercutting the floor; grow(x, 1.0) == x.
    private static func grow(_ value: Int, _ scale: Double) -> Int {
        max(value, Int(Double(value) * scale))
    }
}

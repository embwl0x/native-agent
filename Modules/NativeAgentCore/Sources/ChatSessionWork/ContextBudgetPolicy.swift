import Foundation
import NativeAgentCore
import ProviderRouting
import os
// Blueprint: | `ContextBudgetPolicy.swift` | ContextBudgetPolicy owner. |

/// Scale derived prompt budgets with the effective window without undercutting floors.
public enum ContextBudgetPolicy {

    // MARK: - Tuning constants (every number in this file, nowhere else)

    /// Use a low characters-per-token estimate to request fewer characters than the window can hold.
    package static let charactersPerToken = 3.2

    /// Share transcript-size approximation across request sizing and status; model spelling cannot establish a tokenizer.
    /// The prompt-budget ratio is a separate safety margin.
    package static let transcriptCharactersPerToken = 3.5

    /// History fitting uses the input budget; current input may use the physical limit.
    package static func inputTokens(windowTokens: Int, outputTokens: Int) -> Int {
        min(physicalInputTokens(windowTokens: windowTokens, outputTokens: outputTokens), 200_000)
    }

    /// Refusal and result pointers use model window minus response allowance, the physical limit.
    package static func physicalInputTokens(windowTokens: Int, outputTokens: Int) -> Int {
        let window = max(0, windowTokens)
        let output = max(0, outputTokens)
        return window > output ? window - output : 0
    }

    static let combinedUtilizationFraction = 0.25

    /// Keep floors through 32,768 tokens because fixed assembled context already occupies a substantial share of small windows.
    static let floorWindowTokens = 32_768

    /// The 22k reference mass preserves gentle per-row scaling; it is never an aggregate replay allowance.
    static let referenceFloorTotalCharacters =
        22_000 + (5 * (1_200 + memoryRowOverheadChars)) + 4_000

    static let maximumMemoryBlockCharacters = 24_000
    static let maximumRelevantCharacters = 24_000
    static let maximumCapsuleCharacters = 8_000
    static let maximumPacketCharacters = 32_000
    static let maximumPacketExpandedCharacters = 48_000
    static let maximumPacketPostMandatoryReserve = 40_000

    /// Cap row growth at 4× so larger windows admit more rows without letting one pathological row consume the block.
    static let maximumRowScale = 4.0

    /// Leave room for bullet, newline and provenance markup inside the block cap.
    static let memoryRowOverheadChars = 64

    static let baseRecallRowLimit = 5
    package static let wideRecallRowLimit = 12
    static let wideRecallWindowTokens = 120_000

    // MARK: - Packet atom rendering (NORTHSTAR clause 6: reach, not weight)

    /// Long atoms become leads with expansion pointers; this threshold is window-independent.
    package static let packetAtomExpandThresholdChars = 400

    // MARK: - Floors (today's literals, verbatim)

    /// Return the floor table unchanged below the scaling threshold.
    public struct Floors: Sendable {
        public let relevantChars: Int
    }

    /// Every door assembles the same model input; delivery owns reply limits.
    static let floors = Floors(
        relevantChars: 2_400
    )

    // Keep this product aligned with UserMDAutogenMarkers.promptByteCap, which cannot read these constants.
    static let floorMemoryRowChars = 1_200
    static let floorRecallRowLimit = 5
    static let floorCapsuleChars = 4_000
    static let floorPacketChars = 6_000
    static let floorPacketExpandedChars = 24_000
    static let floorPacketPostMandatoryReserve = 4_000

    // MARK: - Resolved budget

    /// Share budget fields directly with the history renderer so policy cannot drift.
    public struct Resolved: Sendable {
        public let relevantChars: Int

        public let recallRowLimit: Int
        public let memoryRowChars: Int
        public let memoryBlockChars: Int

        public let capsuleChars: Int

        public let packetChars: Int
        public let packetExpandedChars: Int
        public let packetPostMandatoryReserve: Int

        public let windowTokens: Int?
        public let isDerived: Bool
    }

    /// Scaling input for derived budgets, never a cap on their sum.
    public static func derivedCharacterAllowance(windowTokens: Int) -> Int {
        Int(Double(windowTokens) * charactersPerToken * combinedUtilizationFraction)
    }

    /// Use the effective window; unresolved model or route windows remain unavailable.
    public static func windowTokens(
        forModel modelID: String?,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int? {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return ProviderRouting.verifiedContextLength(forModel: raw, providerID: providerID, dataRoot: dataRoot)
    }

    // MARK: - Resolution

    /// Preparation uses the route held by its turn, never a picker reread or a context projection.
    public static func resolve(turn: Turn, dataRoot: URL?) throws -> Resolved {
        guard let admission = turn.admission,
              !admission.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !admission.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRoutingError.configurationFailed("Admit this turn's provider and model before preparing its context.")
        }
        return try resolve(model: admission.model, providerID: admission.provider, dataRoot: dataRoot)
    }

    /// Cache only the pure projection by effective window; resolve model and catalog authority on every model-based call.
    private static let resolvedGeneration = OSAllocatedUnfairLock<Resolved?>(initialState: nil)

    /// Require the admitted model's actual room.
    public static func resolve(windowTokens: Int?) throws -> Resolved {
        guard let windowTokens, windowTokens > 0 else {
            throw ProviderRoutingError.configurationFailed(
                "The selected model's context window is unavailable. Refresh its catalog in Providers before preparing this turn.")
        }
        guard windowTokens > floorWindowTokens else {
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
        // Never scale below the shared floor total.
        let scale = max(1.0, Double(allowance) / Double(referenceFloorTotalCharacters))
        let rowScale = min(scale, maximumRowScale)

        let recallRowLimit = windowTokens >= wideRecallWindowTokens
            ? wideRecallRowLimit
            : baseRecallRowLimit
        // Bound row size by both gentle growth and its share of the memory block after row-count growth.
        let memoryRowChars = min(
            grow(floorMemoryRowChars, rowScale),
            max(
                floorMemoryRowChars,
                (maximumMemoryBlockCharacters / recallRowLimit) - memoryRowOverheadChars
            )
        )

        return Resolved(
            relevantChars: min(maximumRelevantCharacters, grow(floors.relevantChars, scale)),
            recallRowLimit: recallRowLimit,
            memoryRowChars: memoryRowChars,
            // Account for rendered row markup so a full final row still fits the aggregate bound.
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

    public static func resolve(
        model: String?,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) throws -> Resolved {
        try resolve(
            windowTokens: windowTokens(
                forModel: model, providerID: providerID, dataRoot: dataRoot
            )
        )
    }

    // MARK: - Internals

    /// Preserve windowTokens for tracing even when the floor regime needs no scaling.
    private static func floorBudget(floors: Floors, windowTokens: Int?) -> Resolved {
        Resolved(
            relevantChars: floors.relevantChars,
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

    /// Truncate scaled values without undercutting the floor.
    private static func grow(_ value: Int, _ scale: Double) -> Int {
        max(value, Int(Double(value) * scale))
    }
}

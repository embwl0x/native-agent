import Foundation

/// Weekly retention sweep for the evolution proposal store (tightness round 2
/// P-M2). `EvolutionProposalStore.sweep(olderThanDays:)` drops TERMINAL proposals
/// older than the cutoff, but it had zero production callers — `proposals.json`
/// only ever grew. This loop gives it a driver.
///
/// Dependency-clean: the actual prune is an injected closure (the assembly wires
/// it to `EvolutionProposalStore(dataRoot:).sweep()`), so BackgroundLoops gains
/// no SelfImprovement dependency — the same pattern as WeeklySelfImprovementLoop's
/// injected `stageProposal` / `fileCodeFinding`.
///
/// No once-per-period reservation: the sweep is idempotent (a terminal proposal
/// past the cutoff is removed once; a second same-week tick simply finds nothing
/// left to remove), so a double-tick across the BGTask + in-app scheduler wastes
/// one cheap read, never corrupts state. The weekly `interval` is the cadence.
public struct EvolutionProposalRetentionLoop: LoopRunner {
    public let loopId: String = "evolution_proposal_retention"
    public let interval: TimeInterval
    /// Removes terminal proposals older than the store's cutoff and returns how
    /// many rows were dropped (for the log). Injected so this module needs no
    /// SelfImprovement dependency.
    private let sweep: @Sendable () async throws -> Int

    public init(
        interval: TimeInterval = 7 * 24 * 60 * 60,
        sweep: @escaping @Sendable () async throws -> Int
    ) {
        self.interval = interval
        self.sweep = sweep
    }

    public func tickOutcome() async -> LoopTickOutcome {
        do {
            let removed = try await sweep()
            if removed > 0 {
                NSLog("evolution_proposal_retention: swept %d terminal proposal(s)", removed)
            }
            return .completed(result: "evolution proposal sweep removed \(removed)")
        } catch {
            NSLog("evolution_proposal_retention: sweep failed: %@", String(describing: error))
            return .failed(error: String(describing: error))
        }
    }
}

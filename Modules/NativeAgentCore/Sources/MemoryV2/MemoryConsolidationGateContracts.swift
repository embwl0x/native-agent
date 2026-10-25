import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryConsolidationGateContracts.swift` | `MemoryConsolidationDiff` struct |

// MARK: - Outcome shapes

/// Rows merged/dropped summary carried on the card and the receipt.
public struct MemoryConsolidationDiff: Sendable, Equatable {
    public let memoriesActiveBefore: Int
    public let memoriesActiveAfter: Int
    public let proposalsPendingBefore: Int
    public let proposalsPendingAfter: Int
    public let merged: Int
    public let archived: Int

    public init(
        memoriesActiveBefore: Int, memoriesActiveAfter: Int,
        proposalsPendingBefore: Int, proposalsPendingAfter: Int,
        merged: Int, archived: Int
    ) {
        self.memoriesActiveBefore = memoriesActiveBefore
        self.memoriesActiveAfter = memoriesActiveAfter
        self.proposalsPendingBefore = proposalsPendingBefore
        self.proposalsPendingAfter = proposalsPendingAfter
        self.merged = merged
        self.archived = archived
    }

    public var summary: String {
        "memories \(memoriesActiveBefore)→\(memoriesActiveAfter) active; "
            + "proposals pending \(proposalsPendingBefore)→\(proposalsPendingAfter); "
            + "\(merged) merged, \(archived) archived"
    }
}

public enum GatedConsolidationOutcome: Sendable {
    /// A pending swap card already exists — nothing new staged.
    case alreadyStaged(approvalId: String)
    /// Consolidation found nothing to change; no card staged.
    case noChanges(plan: ConsolidationReport)
    /// Candidate scored below live on the probe set — refused to stage.
    case refusedRegression(scores: MemoryProbeComparison, plan: ConsolidationReport)
    /// New candidate staged for approval; prior approved swaps may have applied.
    case staged(
        approvalId: String,
        scores: MemoryProbeComparison,
        diff: MemoryConsolidationDiff,
        plan: ConsolidationReport
    )
}

public enum MemoryConsolidationSwapOutcome: Sendable, Equatable {
    case applied(runId: String, backupPath: String)
    case alreadyApplied(runId: String)
    case staleRefused(runId: String)
    case cleanedUpDenied(runId: String)
    case pendingApproval(runId: String)
    /// Canonical changes committed; derived projections still need reconciliation.
    case projectionFailed(runId: String, reason: String)
    case failed(runId: String, reason: String)
}

struct MemoryConsolidationProjectionEnvironment: Sendable {
    let personaRoot: URL
    let spotlightClient: any SpotlightIndexClient
    let publishInvalidation: @Sendable (DerivedSourceChange) async -> Void

    static func live(dataRoot: URL) -> Self {
        let client: any SpotlightIndexClient
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            #if canImport(CoreSpotlight) && !os(Linux)
            client = SystemSpotlightIndexClient()
            #else
            client = MockSpotlightIndexClient()
            #endif
        } else {
            // Alternate/test roots must never erase or populate the user's
            // system Spotlight index.
            client = MockSpotlightIndexClient()
        }
        return Self(
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot),
            spotlightClient: client,
            publishInvalidation: { change in
                await DerivedStateInvalidationCenter.shared.publish(change)
            }
        )
    }
}

public enum MemoryConsolidationGateError: Error, CustomStringConvertible, LocalizedError {
    case probeGateUnavailable(String)
    case candidateBuildFailed(String)
    case stagingFailed(String)
    case reconcileFailed(String)

    public var failure: ToolFailureError {
        let code: String
        let detail: String
        let instruction: String
        switch self {
        case .probeGateUnavailable(let why):
            code = "memory_consolidation_probe_unavailable"
            detail = "Memory consolidation verification is unavailable: \(why)"
            instruction = "Repair the reported verification input or memory search model before consolidating."
        case .candidateBuildFailed(let why):
            code = "memory_consolidation_candidate_failed"
            detail = "Candidate memory store build failed: \(why)"
            instruction = "Repair the reported candidate memory store error before consolidating."
        case .stagingFailed(let why):
            code = "memory_consolidation_staging_failed"
            detail = "Consolidation approval staging failed; the new candidate was not applied: \(why)"
            instruction = "Inspect approvals and repair the reported staging error before creating another candidate."
        case .reconcileFailed(let why):
            code = "memory_consolidation_reconcile_failed"
            detail = "Prior consolidation reconciliation failed; new staging stopped: \(why)"
            instruction = "Inspect prior approvals and memory state; repair the reported reconciliation error before staging."
        }
        return ToolFailureError(detail, effects: .unknown, owner: "memory consolidation",
            nextCall: ToolFailureError.call("app", ["page": .string("memories")]), code: code, instruction: instruction)
    }

    public var description: String { MemoryV2Error.describe(failure) }
    public var errorDescription: String? { description }
}

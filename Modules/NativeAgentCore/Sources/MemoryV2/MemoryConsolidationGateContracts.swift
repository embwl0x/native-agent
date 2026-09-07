import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Outcome shapes

/// Rows merged/dropped summary carried on the card and the receipt.
public struct MemoryConsolidationDiff: Sendable, Equatable {
    public let memoriesActiveBefore: Int
    public let memoriesActiveAfter: Int
    public let proposalsPendingBefore: Int
    public let proposalsPendingAfter: Int
    public let accepted: Int
    public let merged: Int
    public let archived: Int

    public init(
        memoriesActiveBefore: Int, memoriesActiveAfter: Int,
        proposalsPendingBefore: Int, proposalsPendingAfter: Int,
        accepted: Int, merged: Int, archived: Int
    ) {
        self.memoriesActiveBefore = memoriesActiveBefore
        self.memoriesActiveAfter = memoriesActiveAfter
        self.proposalsPendingBefore = proposalsPendingBefore
        self.proposalsPendingAfter = proposalsPendingAfter
        self.accepted = accepted
        self.merged = merged
        self.archived = archived
    }

    public var summary: String {
        "memories \(memoriesActiveBefore)→\(memoriesActiveAfter) active; "
            + "proposals pending \(proposalsPendingBefore)→\(proposalsPendingAfter); "
            + "\(accepted) accepted, \(merged) merged, \(archived) archived"
    }
}

public enum GatedConsolidationOutcome: Sendable {
    /// A pending swap card already exists — nothing new staged.
    case alreadyStaged(approvalId: String)
    /// Consolidation found nothing to change; no card staged.
    case noChanges(plan: ConsolidationReport)
    /// Candidate scored below live on the probe set — refused to stage.
    case refusedRegression(scores: MemoryProbeComparison, plan: ConsolidationReport)
    /// Candidate staged for approval; live store untouched.
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
                await DerivedStateInvalidationCenter.shared.flush()
            }
        )
    }
}

public enum MemoryConsolidationGateError: Error, CustomStringConvertible {
    case probeGateUnavailable(String)
    case candidateBuildFailed(String)
    case stagingFailed(String)
    case reconcileFailed(String)

    public var description: String {
        switch self {
        case .probeGateUnavailable(let why):
            return "probe gate unavailable — consolidation refused (fail closed): \(why)"
        case .candidateBuildFailed(let why):
            return "candidate store build failed: \(why)"
        case .stagingFailed(let why):
            return "approval staging failed (live store untouched): \(why)"
        case .reconcileFailed(let why):
            return "pre-stage reconcile failed — staging refused (fail closed): \(why)"
        }
    }
}

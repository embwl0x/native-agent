import ApprovalInbox
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Procedures

// Blueprint: | `WorkshopProcedureExactActivation.swift` | `WorkshopProcedureExactActivationQualifier` and coordinator: event-driven qualification from immutable terminal evidence and exact procedure ledger identity |

/// Event-driven qualification of the one native procedure implementation that
/// currently exists. It reads canonical Workshop records plus the existing
/// procedure ledger only after terminal evidence; it owns no timer, candidate
/// store, authority, or action state.
public enum WorkshopProcedureExactActivationQualifier {
    public static func localFileCopyProposal(
        dataRoot: URL,
        artifact: DeclarativeProcedureArtifact,
        evaluatedAt: Date? = nil
    ) async throws -> ProcedureExactActivationProposal? {
        guard WorkshopCompiledLocalFileCopyPlanner.isEligibleArtifact(artifact),
              artifact.sourceTrajectoryIdentities.count >= 2 else { return nil }
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        let receipts = try await store.loadInvocationReceipts(artifactID: artifact.id)
            .filter {
                $0.dispatched
                    && $0.verified
                    && $0.authorityRechecked
                    && $0.canonicalEvidenceMatched
                    && $0.executorStatus == .verifiedSuccess
            }
            .sorted { lhs, rhs in
                if lhs.requestedAt != rhs.requestedAt { return lhs.requestedAt < rhs.requestedAt }
                return lhs.invocationID < rhs.invocationID
            }
        guard receipts.count >= ProcedureExactActivationProposal.minimumVerifiedExecutions else {
            return nil
        }

        return try await qualifiedProposal(dataRoot: dataRoot, artifact: artifact,
            receipts: Array(receipts.suffix(64)), evaluatedAt: evaluatedAt.map(iso8601))
    }

    private static func qualifiedProposal(
        dataRoot: URL, artifact: DeclarativeProcedureArtifact,
        receipts: [ProcedureInvocationReceipt], evaluatedAt: String?
    ) async throws -> ProcedureExactActivationProposal? {
        let records = await SwiftNativeWorkshopRunner(root: dataRoot).listAll()
        let recordGroups = Dictionary(grouping: records, by: {
            CausalTransitionEvidence.opaqueIdentity($0.id)
        })
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        var qualified: [(receipt: ProcedureInvocationReceipt, trajectory: ProcedureTrajectory)] = []
        qualified.reserveCapacity(receipts.count)
        for receipt in receipts {
            guard receipt.dispatched, receipt.verified, receipt.authorityRechecked,
                  receipt.canonicalEvidenceMatched, receipt.executorStatus == .verifiedSuccess,
                  let matches = recordGroups[receipt.opaqueInputReference],
                  matches.count == 1,
                  let record = matches.first,
                  record.status == "completed",
                  record.verification?.status == .satisfied,
                  record.planningProviderCallCount == 0,
                  record.planningRemovableOrchestrationProviderCallCount == 0,
                  record.hasExactZeroProviderStepAccounting,
                  SwiftNativeWorkshopRunner.procedureContractProjection(plan: record.plan,
                    trustRequired: record.trustRequired, triggerSource: record.triggerSource)
                    .procedureShapeIdentity == artifact.procedureShapeIdentity else {
                return nil
            }
            guard let trajectory = try await runner.matchingProcedureTrajectory(for: artifact, record: record),
                  trajectory.terminalClass == .verifiedSuccess,
                  trajectory.providerCallCount == 0,
                  trajectory.inputInstanceIdentity == receipt.opaqueInputReference else {
                return nil
            }
            qualified.append((receipt, trajectory))
        }
        guard qualified.count >= ProcedureExactActivationProposal.minimumVerifiedExecutions else {
            return nil
        }
        let durations = qualified.map(\.trajectory.durationMilliseconds).sorted()
        let percentileIndex = min(
            durations.count - 1,
            max(0, Int(ceil(Double(durations.count) * 0.95)) - 1)
        )
        guard let latestCanonicalEnd = qualified.map(\.trajectory.endedAt).max() else {
            return nil
        }
        let proposal = ProcedureExactActivationProposal(
            artifactID: artifact.id,
            procedureShapeIdentity: artifact.procedureShapeIdentity,
            procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
            implementationIdentity: WorkshopCompiledLocalFileCopyPlanner.implementationIdentity,
            qualifyingInvocationIDs: qualified.map(\.receipt.invocationID),
            qualifyingTrajectoryIDs: qualified.map(\.trajectory.id),
            verifiedExecutionCount: qualified.count,
            distinctInputCount: Set(qualified.map(\.trajectory.inputInstanceIdentity)).count,
            zeroProviderExecutionCount: qualified.filter {
                $0.trajectory.providerCallCount == 0
            }.count,
            sourceEvidenceTrajectoryCount: artifact.sourceTrajectoryIdentities.count,
            p95ExecutionLatencyMilliseconds: durations[percentileIndex],
            qualificationProtocolIdentity:
                WorkshopCompiledLocalFileCopyPlanner.qualificationProtocolIdentity,
            // Default to immutable canonical evidence time, not wall-clock
            // qualification time. Reconciliation of unchanged evidence must
            // produce the same digest and therefore the same approval card.
            evaluatedAt: evaluatedAt ?? latestCanonicalEnd
        )
        return proposal.validates ? proposal : nil
    }

    /// Rechecks the exact approved evidence package immediately before the
    /// active pointer can be installed. Additional later evidence is harmless;
    /// missing, changed, ambiguous, non-canonical, or provider-backed evidence
    /// fails closed.
    public static func proposalStillMatchesCanonicalEvidence(
        _ proposal: ProcedureExactActivationProposal,
        dataRoot: URL,
        artifact: DeclarativeProcedureArtifact
    ) async -> Bool {
        guard proposal.validates,
              proposal.artifactID == artifact.id,
              proposal.procedureShapeIdentity == artifact.procedureShapeIdentity,
              proposal.procedureID == WorkshopCompiledLocalFileCopyPlanner.procedureID,
              proposal.implementationIdentity
                == WorkshopCompiledLocalFileCopyPlanner.implementationIdentity,
              proposal.sourceEvidenceTrajectoryCount
                == artifact.sourceTrajectoryIdentities.count,
              WorkshopCompiledLocalFileCopyPlanner.isEligibleArtifact(artifact) else {
            return false
        }
        do {
            let invocationIDs = Set(proposal.qualifyingInvocationIDs)
            // A retry after an unverified attempt appends a second row for the
            // same invocation; the verified row is the one that settles it.
            var byInvocation: [String: ProcedureInvocationReceipt] = [:]
            for receipt in try await ProcedureArtifactStore(dataRoot: dataRoot).loadInvocationReceipts(artifactID: artifact.id)
            where invocationIDs.contains(receipt.invocationID) {
                if let kept = byInvocation[receipt.invocationID], kept.verified, !receipt.verified { continue }
                byInvocation[receipt.invocationID] = receipt
            }
            let receipts = Array(byInvocation.values)
            guard Set(byInvocation.keys) == invocationIDs else { return false }

            return try await qualifiedProposal(dataRoot: dataRoot, artifact: artifact,
                receipts: receipts, evaluatedAt: proposal.evaluatedAt) == proposal
        } catch {
            return false
        }
    }

    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}

/// Bounded event seam from verified Workshop consequences into local review.
/// It stages at most one card for the exact evidence digest and stops doing
/// work once the exact procedure is active. It never resolves the card.
public enum WorkshopProcedureActivation {
    /// Returns how many activation-review cards it staged (zero or one).
    @discardableResult
    public static func reconcileLocalFileCopyIfQualified(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Int {
        await reconcileLocalFileCopyIfQualified(
            dataRoot: dataRoot,
            canonicalDataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    @discardableResult
    static func reconcileLocalFileCopyIfQualified(
        dataRoot: URL,
        canonicalDataRoot: URL
    ) async -> Int {
        let canonical = canonicalDataRoot.standardizedFileURL
        guard dataRoot.standardizedFileURL == canonical else { return 0 }
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        if (try? await store.loadActiveExactProcedure(
            procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
            implementationIdentity: WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
        )) != nil { return 0 }
        guard let artifacts = try? await store.loadInstalledArtifacts(
            domain: "workshop_execution"
        ).filter(WorkshopCompiledLocalFileCopyPlanner.isEligibleArtifact),
              artifacts.count == 1,
              let artifact = artifacts.first,
              let proposal = try? await WorkshopProcedureExactActivationQualifier
                .localFileCopyProposal(dataRoot: dataRoot, artifact: artifact) else { return 0 }

        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        guard let prior = try? await inbox.list(filter: ApprovalFilter(
            action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction
        )) else { return 0 }
        // One card per question. A pending card is the question. An answer
        // (approved or denied) for the same artifact and implementation
        // sticks until a further full qualifying set of executions exists;
        // re-asking an approval the store cannot apply only loops.
        let alreadyAsked = prior.contains { record in
            guard let asked = SwiftNativeApprovalInbox
                .procedureExactActivationProposal(from: record),
                  asked.procedureID == proposal.procedureID,
                  asked.artifactID == proposal.artifactID else { return false }
            if record.status == "pending" { return true }
            guard record.decision == ApprovalDecision.approved.rawValue
                    || record.decision == ApprovalDecision.denied.rawValue,
                  asked.implementationIdentity == proposal.implementationIdentity else {
                return false
            }
            // The same evidence is the same question. New evidence asks again once a
            // further qualifying set exists; the qualifier reports at most 64, so the cap counts as enough.
            if proposal.bindingDigest == asked.bindingDigest { return true }
            return proposal.verifiedExecutionCount < min(asked.verifiedExecutionCount
                + ProcedureExactActivationProposal.minimumVerifiedExecutions, 64)
        }
        guard !alreadyAsked else { return 0 }
        return (try? await inbox.stageProcedureExactActivationApproval(proposal)) == nil ? 0 : 1
    }
}

/// One-time launch revalidation of original-v1 artifacts against exact Workshop
/// trajectories and approved review; the store compares every field. No artifact
/// is activated, approved or rewritten. Unreproducible artifacts stay off with reasons.
/// Owns migrations/legacy-revalidation-v1.done: UTF-8 refusal lines, existence-read.
/// Off-disk backup carries this marker; local backup, export and phone sync do not.
/// PrivacyMap lists it at living_fabric/procedures/migrations.
public enum WorkshopProcedureLegacyRevalidation {
    public static func runIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> [String] {
        let marker = dataRoot
            .appendingPathComponent("living_fabric/procedures/migrations/legacy-revalidation-v1.done")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return [] }
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        // An unreadable store is retried next launch rather than marked done.
        guard let artifacts = try? await store.loadInstalledArtifacts() else { return [] }
        var refusals: [String] = []
        var retry = false
        for artifact in artifacts where artifact.requiresLegacyRevalidation {
            let outcome = await revalidate(artifact, store: store, dataRoot: dataRoot)
            if outcome.retry { retry = true; continue }
            if let reason = outcome.refusal {
                refusals.append(
                    "A procedure approved \(artifact.reviewerDecision.decidedAt.prefix(10)) stays off: "
                        + "\(reason). The agent does that task the ordinary way instead "
                        + "(artifact \(artifact.id.prefix(12)))."
                )
            }
        }
        // A read that failed is not evidence: try again next launch.
        guard !retry else { return refusals }
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(refusals.joined(separator: "\n").utf8).write(to: marker)
        return refusals
    }

    private static func revalidate(
        _ artifact: DeclarativeProcedureArtifact,
        store: ProcedureArtifactStore,
        dataRoot: URL
    ) async -> (refusal: String?, retry: Bool) {
        let sources = Set(artifact.sourceTrajectoryIdentities)
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        var trajectories: [ProcedureTrajectory] = []
        for record in await runner.listAll()
        where sources.contains(CausalTransitionEvidence.opaqueIdentity(record.id)) {
            guard let timeline = try? await runner.readTimeline(record.id) else { return (nil, true) }
            trajectories += ProcedureTrajectoryExtractor.extract(
                SwiftNativeWorkshopRunner.causalTransitionEvidence(
                    executionId: record.id, timeline: timeline, record: record
                )
            ).trajectories
        }
        guard trajectories.count == sources.count, Set(trajectories.map(\.id)) == sources,
              let unreviewed = ProcedureCandidateCompiler.evaluate(trajectories: trajectories)
                .first(where: { $0.id == artifact.procedureShapeIdentity }) else {
            return ("the Workshop runs it was learned from are no longer all on disk", false)
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        guard let cards = try? await inbox.list(filter: ApprovalFilter(
            action: SwiftNativeApprovalInbox.procedureReviewApprovalAction
        )) else { return (nil, true) }
        guard let card = cards.first(where: {
            CausalTransitionEvidence.opaqueIdentity($0.id)
                == artifact.reviewerDecision.approvalReceiptIdentity
        }) else {
            return ("the approval it was reviewed under is no longer in the approval inbox", false)
        }
        // The decision is re-minted from the owner's card against the
        // recomputed evidence, never copied from the artifact under test.
        guard let decision = try? await inbox.approvedProcedureReviewerDecision(
            approvalID: card.id,
            proposal: ProcedureReviewProposal(
                candidate: unreviewed, scope: artifact.reviewerDecision.scope
            )
        ), let reviewed = ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories, reviewerDecisions: [decision]
        ).first(where: { $0.id == artifact.procedureShapeIdentity }) else {
            return ("its approval no longer matches the runs it was learned from", false)
        }
        do {
            try await store.revalidateLegacyArtifact(artifact.id, candidate: reviewed)
            return (nil, false)
        } catch {
            return ("recompiling it from its reviewed runs did not reproduce it exactly", false)
        }
    }
}

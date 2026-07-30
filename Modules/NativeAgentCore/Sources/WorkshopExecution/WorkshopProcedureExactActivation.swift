import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore

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

        let boundedReceipts = Array(receipts.suffix(64))
        let records = await SwiftNativeWorkshopRunner(root: dataRoot).listAll()
        let recordGroups = Dictionary(grouping: records, by: {
            CausalTransitionEvidence.opaqueIdentity($0.id)
        })
        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
        var qualified: [(receipt: ProcedureInvocationReceipt, trajectory: ProcedureTrajectory)] = []
        qualified.reserveCapacity(boundedReceipts.count)
        for receipt in boundedReceipts {
            guard let matches = recordGroups[receipt.opaqueInputReference],
                  matches.count == 1,
                  let record = matches.first,
                  record.status == "completed",
                  record.verification?.status == .satisfied,
                  record.planningProviderCallCount == 0,
                  record.planningRemovableOrchestrationProviderCallCount == 0,
                  exactZeroProviderSteps(record),
                  SwiftNativeWorkshopRunner.procedureContractProjection(record: record)
                    .procedureShapeIdentity == artifact.procedureShapeIdentity else {
                return nil
            }
            let timeline = try await runner.readTimeline(record.id)
            let extraction = ProcedureTrajectoryExtractor.extract(
                SwiftNativeWorkshopRunner.causalTransitionEvidence(
                    executionId: record.id,
                    timeline: timeline,
                    record: record
                )
            )
            guard extraction.rejections.isEmpty,
                  extraction.trajectories.count == 1,
                  let trajectory = extraction.trajectories.first,
                  trajectory.terminalClass == .verifiedSuccess,
                  trajectory.providerCallCount == 0,
                  trajectory.inputInstanceIdentity == receipt.opaqueInputReference else {
                return nil
            }
            let replay = ProcedureReplayEngine.replay(
                artifact,
                against: trajectory,
                mode: .historicalExact
            )
            guard replay.status == .matched,
                  replay.matchedStepCount == artifact.transitionTable.count else { return nil }
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
            evaluatedAt: evaluatedAt.map(iso8601) ?? latestCanonicalEnd
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
            let receipts = try await ProcedureArtifactStore(dataRoot: dataRoot)
                .loadInvocationReceipts(artifactID: artifact.id)
                .filter { invocationIDs.contains($0.invocationID) }
            guard receipts.count == invocationIDs.count,
                  Set(receipts.map(\.invocationID)) == invocationIDs else { return false }

            let records = await SwiftNativeWorkshopRunner(root: dataRoot).listAll()
            let recordGroups = Dictionary(grouping: records, by: {
                CausalTransitionEvidence.opaqueIdentity($0.id)
            })
            let runner = SwiftNativeWorkshopRunner(root: dataRoot)
            var trajectories: [ProcedureTrajectory] = []
            trajectories.reserveCapacity(receipts.count)
            for receipt in receipts {
                guard receipt.dispatched,
                      receipt.verified,
                      receipt.authorityRechecked,
                      receipt.canonicalEvidenceMatched,
                      receipt.executorStatus == .verifiedSuccess,
                      let matches = recordGroups[receipt.opaqueInputReference],
                      matches.count == 1,
                      let record = matches.first,
                      record.status == "completed",
                      record.verification?.status == .satisfied,
                      record.planningProviderCallCount == 0,
                      record.planningRemovableOrchestrationProviderCallCount == 0,
                      exactZeroProviderSteps(record),
                      SwiftNativeWorkshopRunner.procedureContractProjection(record: record)
                        .procedureShapeIdentity == artifact.procedureShapeIdentity else {
                    return false
                }
                let timeline = try await runner.readTimeline(record.id)
                let extraction = ProcedureTrajectoryExtractor.extract(
                    SwiftNativeWorkshopRunner.causalTransitionEvidence(
                        executionId: record.id,
                        timeline: timeline,
                        record: record
                    )
                )
                guard extraction.rejections.isEmpty,
                      extraction.trajectories.count == 1,
                      let trajectory = extraction.trajectories.first else { return false }
                let replay = ProcedureReplayEngine.replay(
                    artifact,
                    against: trajectory,
                    mode: .historicalExact
                )
                guard
                      trajectory.terminalClass == .verifiedSuccess,
                      trajectory.providerCallCount == 0,
                      trajectory.inputInstanceIdentity == receipt.opaqueInputReference,
                      replay.status == .matched,
                      replay.matchedStepCount == artifact.transitionTable.count else {
                    return false
                }
                trajectories.append(trajectory)
            }
            let durations = trajectories.map(\.durationMilliseconds).sorted()
            let percentileIndex = min(
                durations.count - 1,
                max(0, Int(ceil(Double(durations.count) * 0.95)) - 1)
            )
            return Set(trajectories.map(\.id))
                    == Set(proposal.qualifyingTrajectoryIDs)
                && Set(trajectories.map(\.inputInstanceIdentity)).count
                    == proposal.distinctInputCount
                && trajectories.allSatisfy { $0.providerCallCount == 0 }
                && durations[percentileIndex]
                    == proposal.p95ExecutionLatencyMilliseconds
        } catch {
            return false
        }
    }

    private static func exactZeroProviderSteps(_ record: WorkshopExecutionRecord) -> Bool {
        guard record.stepsCompleted.count == record.plan.count else { return false }
        return record.stepsCompleted.allSatisfy { row in
            guard case .object(let object) = row,
                  case .int(0)? = object["provider_call_count"],
                  case .int(0)? = object["removable_orchestration_provider_call_count"] else {
                return false
            }
            return true
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Bounded event seam from verified Workshop consequences into local review.
/// It stages at most one card for the exact evidence digest and stops doing
/// work once the exact procedure is active. It never resolves the card.
public enum WorkshopProcedureExactActivationCoordinator {
    public static func reconcileLocalFileCopyIfQualified(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await reconcileLocalFileCopyIfQualified(
            dataRoot: dataRoot,
            canonicalDataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    static func reconcileLocalFileCopyIfQualified(
        dataRoot: URL,
        canonicalDataRoot: URL
    ) async {
        let canonical = canonicalDataRoot.standardizedFileURL
        guard dataRoot.standardizedFileURL == canonical else { return }
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        if (try? await store.loadActiveExactProcedure(
            procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
            implementationIdentity: WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
        )) != nil { return }
        guard let artifacts = try? await store.loadInstalledArtifacts(
            domain: "workshop_execution"
        ).filter(WorkshopCompiledLocalFileCopyPlanner.isEligibleArtifact),
              artifacts.count == 1,
              let artifact = artifacts.first,
              let proposal = try? await WorkshopProcedureExactActivationQualifier
                .localFileCopyProposal(dataRoot: dataRoot, artifact: artifact) else { return }

        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let pending = (try? await inbox.list(filter: ApprovalFilter(
            status: "pending",
            action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction
        ))) ?? []
        let duplicate = pending.contains { record in
            guard let pendingProposal = SwiftNativeApprovalInbox
                .procedureExactActivationProposal(from: record) else { return false }
            return pendingProposal.procedureID == proposal.procedureID
                && pendingProposal.artifactID == proposal.artifactID
        }
        guard !duplicate else { return }
        _ = try? await inbox.stageProcedureExactActivationApproval(proposal)
    }
}

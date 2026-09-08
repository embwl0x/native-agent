import Foundation
import ApprovalInbox
import NativeAgentCore
import NativeAgentEvaluation
import ChatOrchestration
import PersistenceCore
import TrustCenter
import WorkshopExecution

extension ChatDriveMain {
    static func runProcedureOperator(
        action: String,
        dataRootPath: String,
        shapeID: String?,
        approvalID: String?,
        scope: String?,
        sourceRelativePath: String?,
        destinationRelativePath: String?,
        invocationKey: String?
    ) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath, isDirectory: true)
            .standardizedFileURL
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        if action == "status" {
            let status = await store.statusSnapshot()
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.status.v1"),
                "artifactCount": .int(Int64(status.artifactCount)),
                "corruptArtifactCount": .int(Int64(status.corruptArtifactCount)),
                "corruptInvocationCount": .int(Int64(status.corruptInvocationCount)),
                "invocationCount": .int(Int64(status.invocationCount)),
                "manualInvocationCount": .int(Int64(status.manualInvocationCount)),
                "automaticInvocationCount": .int(Int64(status.automaticInvocationCount)),
                "verifiedInvocationCount": .int(Int64(status.verifiedInvocationCount)),
                "activationArtifactCount": .int(Int64(status.activationArtifactCount)),
                "corruptActivationArtifactCount": .int(
                    Int64(status.corruptActivationArtifactCount)
                ),
                "activeAutomaticProcedureCount": .int(
                    Int64(status.activeAutomaticProcedureCount)
                ),
                "automaticSelectionEnabled": .bool(status.automaticSelectionEnabled),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")
            return
        }

        if ["stage-activation", "activate", "deactivate"].contains(action) {
            guard let artifactID = shapeID,
                  artifactID.count == 64,
                  artifactID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw procedureOperatorError(
                    "\(action) requires a lowercase 64-character artifact ID"
                )
            }
            let artifact = try await store.load(artifactID)
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            if action == "deactivate" {
                let active = try await store.loadActiveExactProcedure(
                    procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                    implementationIdentity:
                        WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
                )
                guard active.artifact.id == artifact.id else {
                    throw procedureOperatorError("active procedure artifact does not match")
                }
                try await store.deactivateExact(
                    procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                    expectedActivationID: active.manifest.id
                )
                let output: JSONValue = .object([
                    "schema": .string("procedure.operator.deactivate.v1"),
                    "procedureID": .string(active.manifest.proposal.procedureID),
                    "activationID": .string(active.manifest.id),
                    "automaticSelectionEnabled": .bool(false),
                    "artifactRetained": .bool(true),
                    "rollbackDataMigration": .bool(false),
                ])
                print((try? output.serialize(pretty: true)) ?? "\(output)")
                return
            }
            if action == "stage-activation" {
                guard let proposal = try await WorkshopProcedureExactActivationQualifier
                    .localFileCopyProposal(dataRoot: dataRoot, artifact: artifact) else {
                    throw procedureOperatorError(
                        "artifact does not yet have 12 distinct verified zero-provider canonical executions"
                    )
                }
                let pending = try await inbox.list(filter: ApprovalFilter(
                    status: "pending",
                    action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction
                ))
                let existing = pending.first(where: {
                    SwiftNativeApprovalInbox.procedureExactActivationProposal(from: $0)?
                        .artifactID == proposal.artifactID
                })
                let approval: ApprovalRecord
                if let existing {
                    approval = existing
                } else {
                    approval = try await inbox.stageProcedureExactActivationApproval(proposal)
                }
                let output: JSONValue = .object([
                    "schema": .string("procedure.operator.activation-review.v1"),
                    "approvalID": .string(approval.id),
                    "approvalStatus": .string(approval.status),
                    "artifactID": .string(artifact.id),
                    "proposalDigest": .string(proposal.bindingDigest),
                    "verifiedExecutions": .int(Int64(proposal.verifiedExecutionCount)),
                    "distinctInputs": .int(Int64(proposal.distinctInputCount)),
                    "zeroProviderExecutions": .int(
                        Int64(proposal.zeroProviderExecutionCount)
                    ),
                    "p95ExecutionLatencyMilliseconds": .int(
                        Int64(proposal.p95ExecutionLatencyMilliseconds)
                    ),
                    "localOnly": .bool(true),
                    "remoteResolvable": .bool(false),
                ])
                print((try? output.serialize(pretty: true)) ?? "\(output)")
                return
            }
            guard let approvalID, !approvalID.isEmpty else {
                throw procedureOperatorError("activate requires --approval <resolved-local-id>")
            }
            let approval = try await inbox.get(approvalID)
            guard let proposal = SwiftNativeApprovalInbox
                .procedureExactActivationProposal(from: approval),
                  proposal.artifactID == artifact.id,
                  await WorkshopProcedureExactActivationQualifier
                    .proposalStillMatchesCanonicalEvidence(
                        proposal,
                        dataRoot: dataRoot,
                        artifact: artifact
                    ) else {
                throw procedureOperatorError(
                    "approved activation evidence no longer matches canonical Workshop truth"
                )
            }
            let decision = try await inbox.approvedProcedureExactActivationDecision(
                approvalID: approvalID,
                proposal: proposal
            )
            let activation = try await store.installAndActivateExact(
                proposal: proposal,
                reviewerDecision: decision
            )
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.activate.v1"),
                "activationID": .string(activation.id),
                "artifactID": .string(activation.proposal.artifactID),
                "procedureID": .string(activation.proposal.procedureID),
                "selectionMode": .string(activation.selectionMode),
                "automaticSelectionEnabled": .bool(true),
                "permissionAuthority": .bool(false),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")
            return
        }

        if action == "invoke" {
            guard let artifactID = shapeID,
                  artifactID.count == 64,
                  artifactID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let sourceRelativePath,
                  let destinationRelativePath,
                  let invocationKey,
                  validProcedureInvocationKey(invocationKey) else {
                throw procedureOperatorError(
                    "invoke requires a lowercase 64-character artifact ID, --source and --destination workspace-relative paths, and a stable --invocation-key (1-128 letters, numbers, dot, dash, or underscore)"
                )
            }
            try await invokeCompiledWorkshopProcedure(
                store: store,
                artifactID: artifactID,
                dataRoot: dataRoot,
                sourceRelativePath: sourceRelativePath,
                destinationRelativePath: destinationRelativePath,
                invocationKey: invocationKey
            )
            return
        }

        guard let shapeID,
              shapeID.count == 64,
              shapeID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw procedureOperatorError("a lowercase 64-character shape identity is required")
        }
        let evidence = try await collectOperationalProcedureEvidence(
            dataRoot: dataRoot,
            persistence: SwiftNativePersistenceCore()
        )
        let trajectories = ProcedureTrajectoryExtractor.extract(evidence.transitions).trajectories
        guard let candidate = ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories
        ).first(where: { $0.id == shapeID }) else {
            throw procedureOperatorError("procedure candidate not found in canonical evidence")
        }
        let reviewScope: ProcedureReviewScope
        switch scope ?? "manual" {
        case "manual": reviewScope = .manualOnly
        case "canary": reviewScope = .manualAndCanary
        default: throw procedureOperatorError("scope must be manual or canary")
        }
        let proposal = ProcedureReviewProposal(candidate: candidate, scope: reviewScope)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)

        switch action {
        case "stage-review":
            guard candidate.manualBlockingReasons == [.reviewerDecisionMissing] else {
                throw procedureOperatorError(
                    "candidate has non-review blockers: "
                        + candidate.manualBlockingReasons.map(\.rawValue).joined(separator: ",")
                )
            }
            if reviewScope == .manualAndCanary {
                let nonReviewCanaryBlockers = candidate.canaryBlockingReasons.filter {
                    $0 != .reviewerDecisionMissing && $0 != .reviewerCanaryScopeMissing
                }
                guard nonReviewCanaryBlockers.isEmpty else {
                    throw procedureOperatorError(
                        "candidate is not canary-ready: "
                            + nonReviewCanaryBlockers.map(\.rawValue).joined(separator: ",")
                    )
                }
            }
            let pending = try await inbox.list(filter: ApprovalFilter(
                status: "pending",
                action: SwiftNativeApprovalInbox.procedureReviewApprovalAction
            ))
            let existingApproval = pending.first(where: {
                guard case .object(let payload) = $0.payload,
                      case .string(let pendingShape)? = payload["candidateShapeIdentity"],
                      case .string(let pendingDigest)? = payload["candidateEvidenceDigest"] else {
                    return false
                }
                return pendingShape == proposal.candidateShapeIdentity
                    && pendingDigest == proposal.candidateEvidenceDigest
            })
            let approval = if let existingApproval {
                existingApproval
            } else {
                try await inbox.stageProcedureReviewApproval(proposal)
            }
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.review.v1"),
                "approvalID": .string(approval.id),
                "approvalStatus": .string(approval.status),
                "shapeIdentity": .string(candidate.id),
                "trajectoryCount": .int(Int64(candidate.trajectoryCount)),
                "distinctInputs": .int(Int64(candidate.distinctInputInstanceCount)),
                "verifiedSuccesses": .int(Int64(candidate.verifiedSuccessCount)),
                "verifiedSuccessRate": .double(candidate.verifiedSuccessRate),
                "removableProviderCalls": candidate.measurableRemovableProviderCalls
                    .map { .int(Int64($0)) } ?? .null,
                "scope": .string(reviewScope.rawValue),
                "localOnly": .bool(true),
                "remoteResolvable": .bool(false),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")

        case "compile":
            guard let approvalID, !approvalID.isEmpty else {
                throw procedureOperatorError("compile requires --approval <resolved-local-id>")
            }
            let decision = try await inbox.approvedProcedureReviewerDecision(
                approvalID: approvalID,
                proposal: proposal
            )
            guard let reviewed = ProcedureCandidateCompiler.evaluate(
                trajectories: trajectories,
                reviewerDecisions: [decision]
            ).first(where: { $0.id == shapeID }), reviewed.manualInvocationEligible else {
                throw procedureOperatorError("reviewed candidate is not eligible for manual invocation")
            }
            let artifact = try DeclarativeProcedureCompiler.compile(reviewed)
            let replay = reviewed.sourceTrajectories.map {
                ProcedureReplayEngine.replay(artifact, against: $0, mode: .historicalExact)
            }
            guard replay.allSatisfy({
                $0.status == .matched
                    && $0.matchedStepCount == artifact.transitionTable.count
            }) else {
                throw procedureOperatorError("historical exact replay diverged; artifact not installed")
            }
            _ = try await store.install(artifact)
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.compile.v1"),
                "artifactID": .string(artifact.id),
                "shapeIdentity": .string(artifact.procedureShapeIdentity),
                "sourceTrajectoryCount": .int(Int64(artifact.sourceTrajectoryIdentities.count)),
                "replayedTrajectoryCount": .int(Int64(replay.count)),
                "manualInvocationEligible": .bool(artifact.manualInvocationEligible),
                "canaryEligible": .bool(artifact.canaryEligible),
                "automaticSelectionEligible": .bool(false),
                "permissionAuthority": .bool(false),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")

        default:
            throw procedureOperatorError(
                "action must be status, stage-review, compile, invoke, stage-activation, activate, or deactivate"
            )
        }
    }

    /// Manual proof seam for the first provider-free procedure target. The
    /// procedure store remains the artifact/invocation owner; Workshop remains
    /// the canonical executor; Desk remains the task identity; Trust Center is
    /// re-read at admission and before every tool action. This command adds no
    /// automatic selector and cannot invoke external-send or process-global
    /// tools.
    private static func invokeCompiledWorkshopProcedure(
        store: ProcedureArtifactStore,
        artifactID: String,
        dataRoot: URL,
        sourceRelativePath: String,
        destinationRelativePath: String,
        invocationKey: String
    ) async throws {
        let artifact = try await store.load(artifactID)
        let invocation = try WorkshopCompiledLocalFileCopyInvocation(
            artifact: artifact,
            dataRoot: dataRoot,
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            invocationKey: invocationKey,
            store: store
        )
        let startedAt = Date()
        let dispatcher = SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: false,
            enforceLazyToolLoading: false
        )
        let outcome = try await invocation.invokeManual(
            policyAllowed: {
                await workshopProcedurePolicyAllows(dataRoot: dataRoot)
            },
            toolDispatch: { tool, arguments in
                return try await dispatcher.dispatch(
                    tool: tool,
                    input: arguments,
                    surface: "procedure"
                )
            }
        )
        let receipt = outcome.receipt
        let finalRecord = outcome.execution
        let providerAccounting = exactWorkshopProviderAccounting(finalRecord)
        let verificationStatus: JSONValue = finalRecord.verification
            .map { .string($0.status.rawValue) } ?? .null
        let planningCalls: JSONValue = finalRecord.planningProviderCallCount
            .map { .int(Int64($0)) } ?? .null
        let totalCalls: JSONValue = providerAccounting
            .map { .int(Int64($0.providerCalls)) } ?? .null
        let removableCalls: JSONValue = providerAccounting
            .map { .int(Int64($0.removableCalls)) } ?? .null
        let elapsed = Int64(Date().timeIntervalSince(startedAt) * 1_000)
        var fields: [String: JSONValue] = [
            "schema": .string("procedure.operator.invoke.v1"),
            "artifactID": .string(artifact.id),
            "invocationID": .string(receipt.invocationID),
            "opaqueExecutionIdentity": .string(outcome.opaqueExecutionIdentity),
            "deskAlias": outcome.deskAlias.map(JSONValue.string) ?? .null,
            "workshopStatus": .string(finalRecord.status),
            "verificationStatus": verificationStatus,
            "planningProviderCalls": planningCalls,
            "totalProviderCalls": totalCalls,
            "removableOrchestrationProviderCalls": removableCalls,
            "procedureVerified": .bool(receipt.verified),
            "authorityRechecked": .bool(receipt.authorityRechecked),
            "canonicalEvidenceMatched": .bool(receipt.canonicalEvidenceMatched),
            "automaticSelection": .bool(false),
            "permissionAuthority": .bool(false),
            "retrySafe": .bool(true),
            "elapsedMilliseconds": .int(elapsed),
            "payloadFree": .bool(true),
        ]
        fields["verificationMethods"] = .array(
            (finalRecord.verification?.methods ?? []).map(JSONValue.string)
        )
        let output: JSONValue = .object(fields)
        print((try? output.serialize(pretty: true)) ?? "\(output)")
    }

    private static func validProcedureInvocationKey(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        return raw.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func workshopProcedurePolicyAllows(dataRoot: URL) async -> Bool {
        do {
            // The checked canonical owner distinguishes missing state (merge
            // defaults) from damaged saved authority (throw/fail closed).
            let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot)
                .loadTrustPolicyChecked()
            return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
        } catch {
            return false
        }
    }

    private static func exactWorkshopProviderAccounting(
        _ record: WorkshopExecutionRecord
    ) -> (providerCalls: Int, removableCalls: Int)? {
        guard let planning = record.planningProviderCallCount,
              let planningRemovable = record.planningRemovableOrchestrationProviderCallCount,
              planning >= 0, planningRemovable >= 0, planningRemovable <= planning else {
            return nil
        }
        var providers = planning
        var removable = planningRemovable
        for row in record.stepsCompleted {
            guard case .object(let object) = row,
                  case .int(let provider)? = object["provider_call_count"],
                  case .int(let removed)? = object["removable_orchestration_provider_call_count"],
                  provider >= 0, removed >= 0, removed <= provider else { return nil }
            let (nextProviders, providerOverflow) = providers.addingReportingOverflow(Int(provider))
            let (nextRemovable, removableOverflow) = removable.addingReportingOverflow(Int(removed))
            guard !providerOverflow, !removableOverflow else { return nil }
            providers = nextProviders
            removable = nextRemovable
        }
        guard removable <= providers else { return nil }
        return (providers, removable)
    }

    private static func procedureOperatorError(_ message: String) -> NSError {
        NSError(
            domain: "NativeAgentProcedureOperator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Exact builder/operator cancellation for a named Workshop execution.
    /// It delegates to the canonical Workshop store owner and prints only the
    /// bounded lifecycle projection; no objective, plan arguments, or output
    /// payload crosses this proof seam.
    static func runWorkshopCancel(dataRootPath: String, executionID: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: false,
            root: dataRoot,
            enableAutonomy: false
        )
        let record = try await runner.cancel(executionId: executionID)
        let action = try await runner.motorActionReadModel(actionId: executionID)
        let output: JSONValue = .object([
            "schema": .string("workshop.cancel.receipt.v1"),
            "executionIdentity": .string(CausalTransitionEvidence.opaqueIdentity(record.id)),
            "status": .string(record.status),
            "phase": action.map { .string($0.phase.rawValue) } ?? .null,
            "verification": action.map { .string($0.verification.rawValue) } ?? .null,
            "payloadFree": .bool(true),
        ])
        print((try? output.serialize(pretty: true)) ?? "\(output)")
    }
}

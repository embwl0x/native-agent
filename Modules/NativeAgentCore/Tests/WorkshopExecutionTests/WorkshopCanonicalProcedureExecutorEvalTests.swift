import Testing
import Foundation
@testable import WorkshopExecution
@testable import PersistenceCore
import NativeAgentCore

// Coverage ledger: `workshop.canonicalProcedureExecutor`
// (WorkshopCanonicalProcedureExecutor.swift,
//  `WorkshopCompiledProcedureInvocationExecutor.executeProcedureRule`).
//
// SILENT-FAILURE CLASS: dead control. This is the seam PersistenceCore's
// procedure layer calls to actually RUN a compiled rule. If the conformance
// stops being installed, or the `SubmitAndExecute` closure is nil-wired, every
// procedure rule resolves to a no-op and the invocation receipt records a
// non-dispatch — which looks EXACTLY like "nothing qualified". The whole point
// of this eval is to make those two outcomes distinguishable:
//
//   * gate refused          → `.abstained`, authorityRechecked FALSE, ZERO dispatches
//   * gate admitted         → EXACTLY ONE dispatch, authorityRechecked TRUE
//   * evidence didn't match → `.unverified`, verified FALSE (never a quiet success)
//   * submit threw          → the error PROPAGATES (never a swallowed abstain)
//
// NOT covered here: the `.verifiedSuccess` tail, which needs a full timeline
// replay plus a motor-action read model — an integration fixture far outside
// this row's cost budget. It is reported as a remaining gap.

private let evalShapeIdentity = CausalTransitionEvidence.opaqueIdentity("workshop-eval-shape")
private let evalSchemaIdentity = CausalTransitionEvidence.opaqueIdentity("workshop-eval-schema")
private let evalExecutionID = "canonical-eval-execution"

private func procedureEvalRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopProcedureEval-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func admissionRule(
    actionKind: String = "queue_admission",
    sequence: Int = 0,
    beforeState: String? = nil,
    afterState: String? = "queued"
) -> ProcedureTransitionRule {
    ProcedureTransitionRule(
        sequence: sequence,
        beforeState: beforeState,
        onTransitionKind: "enqueued",
        actionKind: actionKind,
        requiredEvidenceKind: "canonical_receipt",
        expectedNextEvidence: "next_evidence",
        checkpointClass: "trust_center_admission",
        externalEffectClass: "local_control",
        afterState: afterState,
        verificationClass: "observed",
        terminalClass: nil
    )
}

/// The minimum artifact the admission gate accepts. Every named field is one
/// of the gate's conjuncts, so a test can flip exactly one and watch the gate
/// bite.
private func evalArtifact(
    domain: String = "workshop_execution",
    authorityClass: String = "low_risk",
    manualInvocationEligible: Bool = true,
    automaticSelectionEligible: Bool = false,
    externalSendsEligible: Bool = false,
    trustCenterCapability: String = "workshop_execution",
    verdict: ProcedureReviewVerdict = .approve,
    rule: ProcedureTransitionRule = admissionRule()
) -> DeclarativeProcedureArtifact {
    DeclarativeProcedureArtifact(
        schema: DeclarativeProcedureArtifact.schema,
        id: "artifact-canonical-eval",
        interpretation: "workshop admission eval",
        sourceTrajectoryIdentities: [CausalTransitionEvidence.opaqueIdentity("trajectory-1")],
        domain: domain,
        procedureShapeIdentity: evalShapeIdentity,
        inputContract: ProcedureInputContract(
            taskFamily: "workshop.routine",
            inputClass: "manual",
            parameterSchemaClass: "typed_step_arguments_v1",
            acceptedParameterSchemaIdentities: [evalSchemaIdentity],
            allowedExternalEffectClasses: ["local_control", "local_read"]
        ),
        authorityClass: authorityClass,
        canonicalOracle: .workshopRecordAndTimeline,
        transitionTable: [rule],
        safety: ProcedureSafetyDeclaration(
            trustCenterCapability: trustCenterCapability,
            requiredPreconditions: [],
            recheckPoints: [.beforeInvocation],
            canonicalApprovalOwner: nil,
            externalSendsEligible: externalSendsEligible,
            permissionAuthority: false,
            automaticActivationAllowed: false
        ),
        deterministicAbandonConditions: [],
        deterministicFallback: .ordinaryWorkshopPlannerExecutor,
        rollbackDeclaration: "no_rollback_required",
        reviewerDecision: ProcedureReviewerDecision(
            candidateShapeIdentity: evalShapeIdentity,
            verdict: verdict,
            scope: .manualOnly,
            reviewerIdentity: CausalTransitionEvidence.opaqueIdentity("reviewer"),
            approvalReceiptIdentity: CausalTransitionEvidence.opaqueIdentity("receipt"),
            candidateEvidenceDigest: CausalTransitionEvidence.opaqueIdentity("digest"),
            decidedAt: "2026-07-13T09:00:00Z"
        ),
        manualInvocationEligible: manualInvocationEligible,
        canaryEligible: false,
        automaticSelectionEligible: automaticSelectionEligible,
        generatedExecutableCode: false
    )
}

private let evalContract = WorkshopProcedureContractProjection(
    taskFamily: "workshop.routine",
    inputClass: "manual",
    parameterSchemaClass: "typed_step_arguments_v1",
    parameterSchemaIdentity: evalSchemaIdentity,
    procedureShapeIdentity: evalShapeIdentity,
    authorityClass: "low_risk",
    externalEffectClasses: ["local_control"]
)

private actor DispatchRecorder {
    private var invocationIDs: [String] = []
    func record(_ id: String) { invocationIDs.append(id) }
    func count() -> Int { invocationIDs.count }
    func ids() -> [String] { invocationIDs }
}

private func evalRecord(id: String) -> WorkshopExecutionRecord {
    let stamp = "2026-07-13T09:00:00Z"
    return WorkshopExecutionRecord(
        id: id, title: "t", objective: "o", createdAt: stamp, status: "completed",
        plan: [], stepsCompleted: [], receiptsDir: "/tmp/eval", triggerSource: "manual",
        trustRequired: "none", expectedOutputs: [], currentStepId: "", updatedAt: stamp,
        result: .null, rerunCount: 0
    )
}

private func makeExecutor(
    root: URL,
    expectedExecutionID: String = evalExecutionID,
    submit: @escaping WorkshopCompiledProcedureInvocationExecutor.SubmitAndExecute
) -> WorkshopCompiledProcedureInvocationExecutor {
    WorkshopCompiledProcedureInvocationExecutor(
        runner: SwiftNativeWorkshopRunner(executorAvailable: true, root: root),
        expectedExecutionID: expectedExecutionID,
        expectedContract: evalContract,
        submitAndExecute: submit
    )
}

private let matchingOpaqueReference = CausalTransitionEvidence.opaqueIdentity(evalExecutionID)

@Suite("EVAL workshop.canonicalProcedureExecutor")
struct WorkshopCanonicalProcedureExecutorEvalSuite {

    /// A REFUSED gate must abstain WITHOUT touching the submit seam. Each case
    /// flips exactly one conjunct; every one of them must produce a
    /// zero-dispatch abstain, and `authorityRechecked == false` is what marks
    /// this as "never got as far as running", not "ran and could not verify".
    @Test func refusedGateAbstainsWithZeroDispatches() async throws {
        let root = procedureEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(String, DeclarativeProcedureArtifact, String)] = [
            ("wrong domain", evalArtifact(domain: "github_command"), matchingOpaqueReference),
            ("wrong authority class", evalArtifact(authorityClass: "confirm_required"),
             matchingOpaqueReference),
            ("not manually invocable", evalArtifact(manualInvocationEligible: false),
             matchingOpaqueReference),
            ("auto-selection eligible", evalArtifact(automaticSelectionEligible: true),
             matchingOpaqueReference),
            ("external sends eligible", evalArtifact(externalSendsEligible: true),
             matchingOpaqueReference),
            ("wrong trust capability", evalArtifact(trustCenterCapability: "github_connector"),
             matchingOpaqueReference),
            ("unapproved review", evalArtifact(verdict: .hold), matchingOpaqueReference),
            ("wrong action kind", evalArtifact(rule: admissionRule(actionKind: "execute_plan")),
             matchingOpaqueReference),
            ("non-zero sequence", evalArtifact(rule: admissionRule(sequence: 1)),
             matchingOpaqueReference),
            ("non-nil before state", evalArtifact(rule: admissionRule(beforeState: "queued")),
             matchingOpaqueReference),
            ("wrong after state", evalArtifact(rule: admissionRule(afterState: "running")),
             matchingOpaqueReference),
            ("mismatched opaque identity", evalArtifact(),
             CausalTransitionEvidence.opaqueIdentity("some-other-execution")),
        ]

        for (label, artifact, reference) in cases {
            let recorder = DispatchRecorder()
            let executor = makeExecutor(root: root) { invocationID in
                await recorder.record(invocationID)
                return evalRecord(id: evalExecutionID)
            }
            let result = try await executor.executeProcedureRule(
                artifact: artifact,
                rule: artifact.transitionTable[0],
                opaqueInputReference: reference,
                invocationID: "invocation-1"
            )
            #expect(result.status == .abstained, "\(label): expected abstain")
            #expect(result.verified == false, "\(label)")
            #expect(result.authorityRechecked == false,
                    "\(label): an abstain must not claim an authority recheck")
            #expect(result.canonicalEvidenceMatched == false, "\(label)")
            #expect(await recorder.count() == 0,
                    "\(label): a refused gate must NOT dispatch")
        }
    }

    /// An ADMITTED gate dispatches EXACTLY ONCE and carries the invocation id
    /// through unchanged. When the returned record does not match the expected
    /// identity, the outcome is `.unverified` — reported, not silently
    /// promoted. `authorityRechecked == true` is what distinguishes it from the
    /// abstain above.
    @Test func admittedGateDispatchesOnceAndReportsUnverifiedOnMismatch() async throws {
        let root = procedureEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DispatchRecorder()
        let executor = makeExecutor(root: root) { invocationID in
            await recorder.record(invocationID)
            // A record whose id is NOT the expected execution → the post-dispatch
            // identity guard must fail closed.
            return evalRecord(id: "a-different-execution")
        }

        let artifact = evalArtifact()
        let result = try await executor.executeProcedureRule(
            artifact: artifact,
            rule: artifact.transitionTable[0],
            opaqueInputReference: matchingOpaqueReference,
            invocationID: "invocation-42"
        )

        #expect(await recorder.count() == 1, "the admitted gate must dispatch exactly once")
        #expect(await recorder.ids() == ["invocation-42"],
                "the invocation identity must be carried forward verbatim")
        #expect(result.status == .unverified)
        #expect(result.verified == false)
        #expect(result.authorityRechecked == true,
                "a dispatched-but-unverified outcome must be distinguishable from an abstain")
        #expect(result.canonicalEvidenceMatched == false)
    }

    /// Same admitted gate, an identity-matching record that still fails the
    /// zero-provider accounting: still `.unverified`, still exactly one
    /// dispatch. Pins that "ran but could not be proven" never collapses into
    /// a verified status.
    @Test func matchingIdentityWithoutZeroProviderAccountingStaysUnverified() async throws {
        let root = procedureEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DispatchRecorder()
        let executor = makeExecutor(root: root) { invocationID in
            await recorder.record(invocationID)
            var record = evalRecord(id: evalExecutionID)
            record.planningProviderCallCount = 1   // a provider call happened
            record.planningRemovableOrchestrationProviderCallCount = 1
            return record
        }

        let artifact = evalArtifact()
        let result = try await executor.executeProcedureRule(
            artifact: artifact,
            rule: artifact.transitionTable[0],
            opaqueInputReference: matchingOpaqueReference,
            invocationID: "invocation-43"
        )

        #expect(await recorder.count() == 1)
        #expect(result.status == .unverified)
        #expect(result.verified == false)
        #expect(result.authorityRechecked == true)
    }

    /// A refusing / nil-wired submit seam must SURFACE, not silently no-op.
    /// This is the exact "dead control" shape the ledger row names: a broken
    /// dispatch closure that looked like "nothing qualified".
    @Test func throwingSubmitPropagatesRatherThanAbstaining() async throws {
        struct EvalSubmitRefusal: Error {}
        let root = procedureEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DispatchRecorder()
        let executor = makeExecutor(root: root) { invocationID in
            await recorder.record(invocationID)
            throw EvalSubmitRefusal()
        }

        let artifact = evalArtifact()
        await #expect(throws: EvalSubmitRefusal.self) {
            _ = try await executor.executeProcedureRule(
                artifact: artifact,
                rule: artifact.transitionTable[0],
                opaqueInputReference: matchingOpaqueReference,
                invocationID: "invocation-44"
            )
        }
        #expect(await recorder.count() == 1)
    }
}

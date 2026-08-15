import Foundation
import Testing
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore
import ApprovalInbox

@Suite("Workshop provider-free compiled local procedure")
struct WorkshopCompiledLocalFileCopyProcedureTests {
    @Test("approved artifact produces the learned shape without a provider call")
    func deterministicPlanMatchesReviewedContract() async throws {
        let fixture = try makeFixture("deterministic-plan")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let artifact = try makeFileCopyArtifact()
        let planner = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: artifact,
            workspaceRoot: fixture.workspace,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt"
        )
        let runner = SwiftNativeWorkshopRunner(
            root: fixture.dataRoot,
            planner: planner,
            enableAutonomy: true
        )
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(
            title: "Compiled routine",
            objective: "Copy the reviewed local file."
        ))

        #expect(planner.directProviderCallCountPerInvocation == 0)
        #expect(!plan.fromStub)
        #expect(plan.steps.map(\.toolOrAction) == ["read_file", "write_file"])
        #expect(plan.steps.map(\.autonomy) == ["needs_approval", "needs_approval"])
        #expect(planner.contract.procedureShapeIdentity == artifact.procedureShapeIdentity)
        #expect(artifact.inputContract.acceptedParameterSchemaIdentities.contains(
            planner.contract.parameterSchemaIdentity
        ))
    }

    @Test("persisted contract identities are pinned wire values")
    func contractIdentitiesArePinnedWireValues() throws {
        // WIRE FENCE. These digests are persisted inside installed
        // ProcedureArtifactStore artifacts and exact-activation pointers on
        // live installs. If this test fails, the code no longer reproduces the
        // identities that already-approved on-disk artifacts carry, and every
        // live install's compiled local-file-copy preflight breaks with
        // artifactShapeMismatch until re-review/re-activation. A deliberate
        // semantic change must mint a NEW identity + activation, not mutate
        // these values in place.
        //
        // Regression anchor (2026-08-05): an unannotated interpolating closure
        // in `procedureContractProjection` type-inferred to GRDB's `SQL`
        // (transitively visible via MemoryV2), hashing an unstable debug
        // description that embedded a per-process address — identities became
        // nondeterministic and every preflight failed against the stored
        // artifact. Self-consistent tests (fresh artifact vs fresh contract)
        // could not see it; only these pinned constants can.
        let fixture = try makeFixture("identity-pins")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let planner = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: try makeFileCopyArtifact(),
            workspaceRoot: fixture.workspace,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt"
        )
        #expect(planner.contract.taskFamily == "workshop.routine")
        #expect(planner.contract.inputClass == "manual")
        #expect(planner.contract.parameterSchemaClass == "typed_step_arguments_v1")
        #expect(planner.contract.authorityClass == "low_risk")
        #expect(planner.contract.externalEffectClasses
            == ["local_control", "local_read", "local_write"])
        #expect(planner.contract.procedureShapeIdentity
            == "d8623f6ec1d2ad4eed738f99b33ed0ea9119785318987d44b80aaa9f343c8938")
        #expect(planner.contract.parameterSchemaIdentity
            == "6aecd17e49040356f3f2892d9e52ecb31f9ecd99b100003d8dab3a07a231c0d1")
        #expect(WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
            == "6ebfe918402583a5c282f4b8f4744f2f000ee9ad9095221dbec5fa6acf575d3f")
        // Determinism guard: the same synthetic plan must project the same
        // identity within one process (the 2026-08-05 defect varied even
        // run-to-run because the hashed value embedded a runtime address).
        let second = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: try makeFileCopyArtifact(),
            workspaceRoot: fixture.workspace,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt"
        )
        #expect(second.contract.procedureShapeIdentity
            == planner.contract.procedureShapeIdentity)
    }

    @Test("workspace traversal and oversized inputs fail before Workshop submission")
    func inputBoundary() throws {
        let fixture = try makeFixture("input-boundary")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()

        #expect(throws: WorkshopCompiledProcedurePlanError.self) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "../outside.txt",
                destinationRelativePath: "output.txt"
            )
        }

        #expect(throws: WorkshopCompiledProcedurePlanError.sourceUnavailable) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "missing.txt",
                destinationRelativePath: "output.txt"
            )
        }

        #expect(throws: WorkshopCompiledProcedurePlanError.destinationParentUnavailable) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "source.txt",
                destinationRelativePath: "missing-parent/output.txt"
            )
        }

        #expect(throws: WorkshopCompiledProcedurePlanError.sourceEqualsDestination) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "source.txt",
                destinationRelativePath: "source.txt"
            )
        }

        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("outside-link.txt"),
            withDestinationURL: outside
        )
        #expect(throws: WorkshopCompiledProcedurePlanError.pathOutsideWorkspace) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "outside-link.txt",
                destinationRelativePath: "output.txt"
            )
        }

        let large = Data(repeating: 0x61, count: WorkshopCompiledLocalFileCopyPlanner.maximumSourceBytes + 1)
        try large.write(to: fixture.workspace.appendingPathComponent("large.txt"))
        #expect(throws: WorkshopCompiledProcedurePlanError.sourceTooLarge) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "large.txt",
                destinationRelativePath: "output.txt"
            )
        }

        try Data([0xFF, 0xFE]).write(to: fixture.workspace.appendingPathComponent("binary.txt"))
        #expect(throws: WorkshopCompiledProcedurePlanError.sourceNotUTF8) {
            _ = try WorkshopCompiledLocalFileCopyPlanner(
                artifact: artifact,
                workspaceRoot: fixture.workspace,
                sourceRelativePath: "binary.txt",
                destinationRelativePath: "output.txt"
            )
        }
    }

    @Test("compiled invocation rechecks exact bytes and destination boundary after preflight")
    func postPreflightMutationFailsClosed() throws {
        let fixture = try makeFixture("post-preflight-mutation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let planner = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: makeFileCopyArtifact(),
            workspaceRoot: fixture.workspace,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt"
        )
        let readArguments: [String: JSONValue] = [
            "path": .string("workspace/source.txt"),
            "max_bytes": .string("65536"),
        ]

        try Data("changed after preflight".utf8).write(to: fixture.source, options: .atomic)
        #expect(throws: WorkshopCompiledProcedurePlanError.sourceChangedAfterPreflight) {
            try planner.validateBeforeDispatch(tool: "read_file", arguments: readArguments)
        }

        let exactText = "provider-free canonical procedure\n"
        try Data(exactText.utf8).write(to: fixture.source, options: .atomic)
        try planner.validateBeforeDispatch(tool: "read_file", arguments: readArguments)
        #expect(throws: WorkshopCompiledProcedurePlanError.toolResultMismatch) {
            try planner.validateAfterDispatch(
                tool: "read_file",
                result: .string("dispatcher returned different bytes")
            )
        }

        let outside = fixture.root.appendingPathComponent("outside-destination.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("output.txt"),
            withDestinationURL: outside
        )
        #expect(throws: WorkshopCompiledProcedurePlanError.destinationChangedAfterPreflight) {
            try planner.validateBeforeDispatch(tool: "write_file", arguments: [
                "path": .string("workspace/output.txt"),
                "append": .string("false"),
                "content": .string(exactText),
            ])
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test("runtime never reaches write after a mismatched canonical read result")
    func runtimeReadBinding() async throws {
        let fixture = try makeFixture("runtime-read-binding")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()
        let store = ProcedureArtifactStore(dataRoot: fixture.dataRoot)
        _ = try await store.install(artifact)
        let invocation = try WorkshopCompiledLocalFileCopyInvocation(
            artifact: artifact,
            dataRoot: fixture.dataRoot,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt",
            invocationKey: "mismatched-read",
            store: store
        )
        let calls = CompiledProcedureCallRecorder()
        let outcome = try await invocation.invokeManual(
            policyAllowed: { true },
            toolDispatch: { tool, _ in
                await calls.record(tool)
                if tool == "read_file" { return .string("not the preflight bytes") }
                Issue.record("write_file ran after exact read binding failed")
                return .object(["status": .string("succeeded")])
            }
        )

        #expect(await calls.values() == ["read_file"])
        #expect(outcome.execution.status == "failed")
        // The exact procedure deliberately abstains from a verified execution
        // claim because the reviewed two-step contract did not complete.
        #expect(outcome.receipt.executorStatus == .unverified)
        #expect(!outcome.receipt.verified)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("output.txt").path
        ))
    }

    @Test("TrustCenter denial leaves no canonical procedure effect")
    func policyDenialBeforeAdmission() async throws {
        let fixture = try makeFixture("policy-denial")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()
        let store = ProcedureArtifactStore(dataRoot: fixture.dataRoot)
        _ = try await store.install(artifact)
        let invocation = try WorkshopCompiledLocalFileCopyInvocation(
            artifact: artifact,
            dataRoot: fixture.dataRoot,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt",
            invocationKey: "policy-denial",
            store: store
        )
        await #expect(throws: WorkshopCompiledProcedureRuntimeError.policyDenied) {
            _ = try await invocation.invokeManual(
                policyAllowed: { false },
                toolDispatch: { _, _ in
                    Issue.record("tool dispatch ran after policy denial")
                    return .null
                }
            )
        }
        #expect(await SwiftNativeWorkshopRunner(root: fixture.dataRoot).listAll().isEmpty)
        #expect(try await store.loadInvocationReceipts().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("output.txt").path
        ))
    }

    @Test("canonical Workshop execution copies exact bytes with zero provider calls")
    func canonicalExecution() async throws {
        let fixture = try makeFixture("canonical-execution")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()
        let planner = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: artifact,
            workspaceRoot: fixture.workspace,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt"
        )
        let runner = SwiftNativeWorkshopRunner(
            root: fixture.dataRoot,
            planner: planner,
            enableAutonomy: true
        )
        let submitted = try await runner.submit(spec: WorkshopExecutionSpec(
            title: "Compiled routine",
            objective: "Copy the reviewed local file.",
            triggerSource: "manual",
            trustRequired: "none"
        ))
        let outputURL = fixture.workspace.appendingPathComponent("output.txt")
        let loop = WorkshopExecutorLoop(
            root: fixture.dataRoot,
            toolDispatch: { tool, value in
                guard case .object(let arguments) = value else {
                    throw WorkshopExecutionError.invalidRequest("arguments")
                }
                switch tool {
                case "read_file":
                    return .string(try String(contentsOf: fixture.source, encoding: .utf8))
                case "write_file":
                    guard case .string(let content)? = arguments["content"] else {
                        throw WorkshopExecutionError.invalidRequest("content")
                    }
                    try Data(content.utf8).write(to: outputURL, options: .atomic)
                    return .object([
                        "ok": .bool(true),
                        "path": .string(outputURL.path),
                        "status": .string("succeeded"),
                    ])
                default:
                    throw WorkshopExecutionError.invalidRequest("unsupported tool")
                }
            },
            stepApprovalEnforced: { false }
        )
        let final = try await loop.start(executionId: submitted.executionId)

        #expect(final.status == "completed")
        #expect(final.verification?.status == .satisfied)
        #expect(final.verification?.methods.contains("file_bytes") == true)
        #expect(final.planningProviderCallCount == 0)
        #expect(final.planningRemovableOrchestrationProviderCallCount == 0)
        #expect(final.stepsCompleted.count == 2)
        for row in final.stepsCompleted {
            guard case .object(let object) = row else {
                Issue.record("step receipt was not an object")
                continue
            }
            #expect(object["provider_call_count"] == .int(0))
            #expect(object["removable_orchestration_provider_call_count"] == .int(0))
        }
        #expect(try Data(contentsOf: outputURL) == Data(contentsOf: fixture.source))
    }

    @Test("shared production invocation admits once and replays canonical timeline")
    func sharedCompiledInvocationCausalReceipt() async throws {
        let fixture = try makeFixture("compiled-invocation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()
        let store = ProcedureArtifactStore(dataRoot: fixture.dataRoot)
        _ = try await store.install(artifact)
        let invocation = try WorkshopCompiledLocalFileCopyInvocation(
            artifact: artifact,
            dataRoot: fixture.dataRoot,
            sourceRelativePath: "source.txt",
            destinationRelativePath: "output.txt",
            invocationKey: "compiled-invocation",
            store: store
        )
        let outputURL = fixture.workspace.appendingPathComponent("output.txt")
        let outcome = try await invocation.invokeManual(
            policyAllowed: { true },
            toolDispatch: { tool, arguments in
                if tool == "read_file" {
                    return .string(try String(contentsOf: fixture.source, encoding: .utf8))
                }
                guard tool == "write_file",
                      case .string(let content)? = arguments["content"] else {
                    throw WorkshopExecutionError.invalidRequest("unsupported tool")
                }
                try Data(content.utf8).write(to: outputURL, options: .atomic)
                return .object([
                    "ok": .bool(true),
                    "path": .string(outputURL.path),
                    "status": .string("succeeded"),
                ])
            }
        )

        #expect(outcome.receipt.executorStatus == .verifiedSuccess)
        #expect(outcome.receipt.authorityRechecked)
        #expect(outcome.receipt.canonicalEvidenceMatched)
        #expect(outcome.receipt.verified)
        #expect(outcome.execution.status == "completed")
        #expect(outcome.execution.planningProviderCallCount == 0)
        #expect(outcome.execution.verification?.status == .satisfied)
        #expect(outcome.deskAlias != nil)
        #expect(try Data(contentsOf: outputURL) == Data(contentsOf: fixture.source))
    }

    @Test("twelve distinct verified zero-provider executions qualify exact activation")
    func activationQualification() async throws {
        let fixture = try makeFixture("activation-qualification")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = try makeFileCopyArtifact()
        let store = ProcedureArtifactStore(dataRoot: fixture.dataRoot)
        _ = try await store.install(artifact)
        for index in 0..<12 {
            let destination = "output-\(index).txt"
            let invocation = try WorkshopCompiledLocalFileCopyInvocation(
                artifact: artifact,
                dataRoot: fixture.dataRoot,
                sourceRelativePath: "source.txt",
                destinationRelativePath: destination,
                invocationKey: "qualification-\(index)",
                store: store
            )
            let outcome = try await invocation.invokeManual(
                policyAllowed: { true },
                toolDispatch: { tool, arguments in
                    if tool == "read_file" {
                        return .string(try String(contentsOf: fixture.source, encoding: .utf8))
                    }
                    guard tool == "write_file",
                          case .string(let content)? = arguments["content"],
                          case .string(let toolPath)? = arguments["path"],
                          toolPath.hasPrefix("workspace/") else {
                        throw WorkshopExecutionError.invalidRequest("unsupported tool")
                    }
                    let relative = String(toolPath.dropFirst("workspace/".count))
                    let output = fixture.workspace.appendingPathComponent(relative)
                    try Data(content.utf8).write(to: output, options: .atomic)
                    return .object([
                        "ok": .bool(true),
                        "path": .string(output.path),
                        "status": .string("succeeded"),
                    ])
                }
            )
            #expect(outcome.receipt.verified)
            #expect(!outcome.receipt.automaticSelection)
        }
        let proposal = try #require(
            try await WorkshopProcedureExactActivationQualifier.localFileCopyProposal(
                dataRoot: fixture.dataRoot,
                artifact: artifact
            )
        )
        #expect(proposal.validates)
        #expect(proposal.verifiedExecutionCount == 12)
        #expect(proposal.distinctInputCount == 12)
        #expect(proposal.zeroProviderExecutionCount == 12)
        #expect(proposal.sourceEvidenceTrajectoryCount == 2)
        #expect(proposal.procedureID == WorkshopCompiledLocalFileCopyPlanner.procedureID)
        #expect(proposal.implementationIdentity
            == WorkshopCompiledLocalFileCopyPlanner.implementationIdentity)
        #expect(proposal.p95ExecutionLatencyMilliseconds < 60_000)
        let repeatedProposal = try #require(
            try await WorkshopProcedureExactActivationQualifier.localFileCopyProposal(
                dataRoot: fixture.dataRoot,
                artifact: artifact
            )
        )
        #expect(repeatedProposal.bindingDigest == proposal.bindingDigest)
        #expect(await WorkshopProcedureExactActivationQualifier
            .proposalStillMatchesCanonicalEvidence(
                proposal,
                dataRoot: fixture.dataRoot,
                artifact: artifact
            ))

        await WorkshopProcedureExactActivationCoordinator
            .reconcileLocalFileCopyIfQualified(
                dataRoot: fixture.dataRoot,
                canonicalDataRoot: fixture.dataRoot
            )
        await WorkshopProcedureExactActivationCoordinator
            .reconcileLocalFileCopyIfQualified(
                dataRoot: fixture.dataRoot,
                canonicalDataRoot: fixture.dataRoot
            )
        let activationCards = try await SwiftNativeApprovalInbox(root: fixture.dataRoot)
            .list(filter: ApprovalFilter(
                status: "pending",
                action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction
            ))
        #expect(activationCards.count == 1)
        #expect(SwiftNativeApprovalInbox.procedureExactActivationProposal(
            from: try #require(activationCards.first)
        )?.bindingDigest == proposal.bindingDigest)

        let firstReceipt = try #require(
            try await store.loadInvocationReceipts(artifactID: artifact.id).first
        )
        let runner = SwiftNativeWorkshopRunner(root: fixture.dataRoot)
        let firstRecord = try #require(await runner.listAll().first {
            CausalTransitionEvidence.opaqueIdentity($0.id)
                == firstReceipt.opaqueInputReference
        })
        try FileManager.default.removeItem(at: runner.timelinePath(firstRecord.id))
        #expect(!(await WorkshopProcedureExactActivationQualifier
            .proposalStillMatchesCanonicalEvidence(
                proposal,
                dataRoot: fixture.dataRoot,
                artifact: artifact
            )))
    }
}

private actor CompiledProcedureCallRecorder {
    private var calls: [String] = []
    func record(_ tool: String) { calls.append(tool) }
    func values() -> [String] { calls }
}

private struct CompiledProcedureFixture: @unchecked Sendable {
    let root: URL
    let dataRoot: URL
    let workspace: URL
    let source: URL
}

private func makeFixture(_ name: String) throws -> CompiledProcedureFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopCompiledProcedure-\(name)-\(UUID().uuidString)")
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let workspace = dataRoot.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let source = workspace.appendingPathComponent("source.txt")
    try Data("provider-free canonical procedure\n".utf8).write(to: source)
    return CompiledProcedureFixture(
        root: root,
        dataRoot: dataRoot,
        workspace: workspace,
        source: source
    )
}

private func makeFileCopyArtifact() throws -> DeclarativeProcedureArtifact {
    let opaque: (String) -> String = CausalTransitionEvidence.opaqueIdentity
    let steps = [
        WorkshopExecutionStep(
            id: "step-1",
            description: "Read source",
            toolOrAction: "read_file",
            args: .object([
                "max_bytes": .string("65536"),
                "path": .string("workspace/source.txt"),
            ]),
            autonomy: "needs_approval"
        ),
        WorkshopExecutionStep(
            id: "step-2",
            description: "Write destination",
            toolOrAction: "write_file",
            args: .object([
                "append": .string("false"),
                "content": .string("{{step:step-1}}"),
                "path": .string("workspace/output.txt"),
            ]),
            autonomy: "needs_approval"
        ),
    ]
    let record = WorkshopExecutionRecord(
        id: "projection",
        title: "Projection",
        objective: "Projection",
        createdAt: "1970-01-01T00:00:00Z",
        status: "queued",
        plan: steps,
        stepsCompleted: [],
        receiptsDir: "",
        triggerSource: "manual",
        trustRequired: "none",
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: "1970-01-01T00:00:00Z",
        result: .null,
        rerunCount: 0
    )
    let contract = SwiftNativeWorkshopRunner.procedureContractProjection(record: record)
    let transitionTable: [[String: Any?]] = [
        [
            "sequence": 0, "beforeState": nil, "onTransitionKind": "enqueued",
            "actionKind": "queue_admission", "requiredEvidenceKind": "queue_receipt",
            "expectedNextEvidence": "execution_start", "checkpointClass": "trust_center_admission",
            "externalEffectClass": "local_control", "afterState": "queued",
            "verificationClass": "unknown", "terminalClass": nil,
        ],
        [
            "sequence": 1, "beforeState": "queued", "onTransitionKind": "started",
            "actionKind": "execute_plan", "requiredEvidenceKind": "execution_claim",
            "expectedNextEvidence": "step_or_terminal_outcome", "checkpointClass": nil,
            "externalEffectClass": "local_control", "afterState": "running",
            "verificationClass": "unknown", "terminalClass": nil,
        ],
        [
            "sequence": 2, "beforeState": "running", "onTransitionKind": "step_completed",
            "actionKind": "tool:read_file", "requiredEvidenceKind": "step_receipt:succeeded",
            "expectedNextEvidence": "step_or_terminal_outcome", "checkpointClass": nil,
            "externalEffectClass": "local_read", "afterState": "running",
            "verificationClass": "observed", "terminalClass": nil,
        ],
        [
            "sequence": 3, "beforeState": "running", "onTransitionKind": "step_completed",
            "actionKind": "tool:write_file", "requiredEvidenceKind": "step_receipt:succeeded",
            "expectedNextEvidence": "step_or_terminal_outcome", "checkpointClass": nil,
            "externalEffectClass": "local_write", "afterState": "running",
            "verificationClass": "observed", "terminalClass": nil,
        ],
        [
            "sequence": 4, "beforeState": "running", "onTransitionKind": "completed",
            "actionKind": nil, "requiredEvidenceKind": "domain_verification",
            "expectedNextEvidence": nil, "checkpointClass": "domain_outcome_verification",
            "externalEffectClass": "local_control", "afterState": "completed",
            "verificationClass": "verified", "terminalClass": "verified_success",
        ],
    ]
    let cleanedTable: [[String: Any]] = transitionTable.map { row in
        row.compactMapValues { $0 }
    }
    var object: [String: Any] = [
        "schema": DeclarativeProcedureArtifact.schema,
        "id": opaque("compiled-file-copy-artifact"),
        "interpretation": "trusted_declarative_transition_table_v1",
        "sourceTrajectoryIdentities": [opaque("trajectory-1"), opaque("trajectory-2")].sorted(),
        "domain": "workshop_execution",
        "procedureShapeIdentity": contract.procedureShapeIdentity,
        "inputContract": [
            "taskFamily": contract.taskFamily,
            "inputClass": contract.inputClass,
            "parameterSchemaClass": contract.parameterSchemaClass,
            "acceptedParameterSchemaIdentities": [contract.parameterSchemaIdentity],
            "allowedExternalEffectClasses": contract.externalEffectClasses.sorted(),
        ],
        "authorityClass": "low_risk",
        "canonicalOracle": "workshop_record_and_timeline",
        "transitionTable": cleanedTable,
        "safety": [
            "trustCenterCapability": "workshop_execution",
            "requiredPreconditions": [
                "authority_class_matches", "canonical_executor_available",
                "domain_state_matches", "input_schema_matches",
            ],
            "recheckPoints": [
                "before_invocation", "before_every_action", "after_every_checkpoint",
            ],
            "externalSendsEligible": false,
            "permissionAuthority": false,
            "automaticActivationAllowed": false,
        ],
        "deterministicAbandonConditions": ProcedureCandidateCompiler.deterministicAbandonConditions,
        "deterministicFallback": "ordinary_workshop_planner_executor",
        "rollbackDeclaration": "delete_artifact_restore_fallback_no_data_migration",
        "reviewerDecision": [
            "candidateShapeIdentity": contract.procedureShapeIdentity,
            "verdict": "approve",
            "scope": "manual_only",
            "reviewerIdentity": opaque("local-reviewer"),
            "approvalReceiptIdentity": opaque("local-approval"),
            "candidateEvidenceDigest": opaque("evidence"),
            "decidedAt": "2026-07-14T12:00:00Z",
        ],
        "manualInvocationEligible": true,
        "canaryEligible": false,
        "automaticSelectionEligible": false,
        "generatedExecutableCode": false,
    ]
    let provisional = try JSONDecoder().decode(
        DeclarativeProcedureArtifact.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
    let fingerprint = [
        provisional.procedureShapeIdentity,
        provisional.domain,
        provisional.inputContract.taskFamily,
        provisional.inputContract.inputClass,
        provisional.authorityClass,
        provisional.inputContract.acceptedParameterSchemaIdentities.joined(separator: ","),
        provisional.transitionTable.map {
            "\($0.sequence)|\($0.beforeState ?? "nil")|\($0.onTransitionKind)|"
                + "\($0.actionKind ?? "nil")|\($0.requiredEvidenceKind ?? "nil")|"
                + "\($0.externalEffectClass)|\($0.afterState ?? "nil")|"
                + "\($0.terminalClass?.rawValue ?? "nil")"
        }.joined(separator: ">"),
        provisional.reviewerDecision.reviewerIdentity,
        provisional.reviewerDecision.decidedAt,
    ].joined(separator: "||")
    object["id"] = opaque(fingerprint)
    return try JSONDecoder().decode(
        DeclarativeProcedureArtifact.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

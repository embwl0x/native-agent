import Foundation
import NativeAgentCore
import PersistenceCore

public enum WorkshopCompiledProcedureRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case policyDenied
    case unsupportedTool
    case invalidToolArguments
    case queueIdentityDiverged
    case canonicalRecordMissing
    case canonicalObservationEnded

    public var errorDescription: String? {
        switch self {
        case .policyDenied:
            return "Workshop execution is disabled by Trust Center policy."
        case .unsupportedTool:
            return "The compiled Workshop procedure attempted an unsupported tool."
        case .invalidToolArguments:
            return "The compiled Workshop procedure produced invalid tool arguments."
        case .queueIdentityDiverged:
            return "The compiled Workshop queue identity diverged from its invocation binding."
        case .canonicalRecordMissing:
            return "The canonical Workshop record disappeared after procedure invocation."
        case .canonicalObservationEnded:
            return "Canonical Workshop observation ended before a terminal outcome."
        }
    }
}

public struct WorkshopCompiledProcedureInvocationOutcome: Sendable {
    public let artifact: DeclarativeProcedureArtifact
    public let receipt: ProcedureInvocationReceipt
    public let execution: WorkshopExecutionRecord
    public let executionID: String
    public let opaqueExecutionIdentity: String
    public let deskAlias: String?

    public init(
        artifact: DeclarativeProcedureArtifact,
        receipt: ProcedureInvocationReceipt,
        execution: WorkshopExecutionRecord,
        executionID: String,
        opaqueExecutionIdentity: String,
        deskAlias: String?
    ) {
        self.artifact = artifact
        self.receipt = receipt
        self.execution = execution
        self.executionID = executionID
        self.opaqueExecutionIdentity = opaqueExecutionIdentity
        self.deskAlias = deskAlias
    }
}

/// Shared production/manual adapter from an explicitly requested, reviewed
/// local-copy procedure to Workshop's canonical queue. It is not a selector,
/// scheduler, tool owner, or authority owner. The caller supplies the existing
/// TrustCenter read and the existing file-tool dispatcher; this type owns only
/// the exact invocation mechanics that were previously trapped in `chat-drive`.
public struct WorkshopCompiledLocalFileCopyInvocation: Sendable {
    public typealias PolicyAllowed = @Sendable () async -> Bool
    public typealias ToolDispatch = @Sendable (
        _ tool: String,
        _ arguments: [String: JSONValue]
    ) async throws -> JSONValue

    public let artifact: DeclarativeProcedureArtifact
    public let planner: WorkshopCompiledLocalFileCopyPlanner
    public let executionID: String
    public let opaqueExecutionIdentity: String

    private let dataRoot: URL
    private let store: ProcedureArtifactStore
    private let runner: SwiftNativeWorkshopRunner

    public init(
        artifact: DeclarativeProcedureArtifact,
        dataRoot: URL,
        sourceRelativePath: String,
        destinationRelativePath: String,
        invocationKey: String,
        store: ProcedureArtifactStore? = nil
    ) throws {
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        let planner = try WorkshopCompiledLocalFileCopyPlanner(
            artifact: artifact,
            workspaceRoot: workspaceRoot,
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath
        )
        let executionID = CausalTransitionEvidence.opaqueIdentity([
            "compiled-workshop-invocation-v1",
            artifact.id,
            invocationKey,
            planner.operationBindingIdentity,
        ].joined(separator: "|"))
        self.artifact = artifact
        self.planner = planner
        self.executionID = executionID
        self.opaqueExecutionIdentity = CausalTransitionEvidence.opaqueIdentity(executionID)
        self.dataRoot = dataRoot
        self.store = store ?? ProcedureArtifactStore(dataRoot: dataRoot)
        self.runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: dataRoot,
            planner: planner,
            enableAutonomy: true,
            uuid: { executionID }
        )
    }

    public func invokeManual(
        policyAllowed: @escaping PolicyAllowed,
        toolDispatch: @escaping ToolDispatch
    ) async throws -> WorkshopCompiledProcedureInvocationOutcome {
        try await invoke(
            selection: .manual,
            policyAllowed: policyAllowed,
            toolDispatch: toolDispatch
        )
    }

    public func invokeAutomaticExact(
        policyAllowed: @escaping PolicyAllowed,
        toolDispatch: @escaping ToolDispatch
    ) async throws -> WorkshopCompiledProcedureInvocationOutcome {
        try await invoke(
            selection: .automaticExact,
            policyAllowed: policyAllowed,
            toolDispatch: toolDispatch
        )
    }

    private enum Selection: Sendable {
        case manual
        case automaticExact
    }

    private func invoke(
        selection: Selection,
        policyAllowed: @escaping PolicyAllowed,
        toolDispatch: @escaping ToolDispatch
    ) async throws -> WorkshopCompiledProcedureInvocationOutcome {
        guard await policyAllowed() else {
            throw WorkshopCompiledProcedureRuntimeError.policyDenied
        }
        let loop = WorkshopExecutorLoop(
            root: dataRoot,
            toolDispatch: { tool, rawArguments in
                guard tool == "read_file" || tool == "write_file" else {
                    throw WorkshopCompiledProcedureRuntimeError.unsupportedTool
                }
                guard await policyAllowed() else {
                    throw WorkshopCompiledProcedureRuntimeError.policyDenied
                }
                guard case .object(let arguments) = rawArguments else {
                    throw WorkshopCompiledProcedureRuntimeError.invalidToolArguments
                }
                try planner.validateBeforeDispatch(tool: tool, arguments: arguments)
                let result = try await toolDispatch(tool, arguments)
                try planner.validateAfterDispatch(tool: tool, result: result)
                return result
            },
            isEnabled: policyAllowed,
            // The exact immutable artifact was locally reviewed. Intrinsic
            // TrustCenter and workspace checks are still re-run for every
            // action by the supplied canonical dispatcher.
            stepApprovalEnforced: { false },
            terminalEventSink: { record, reason in
                await WorkshopDeskReceiptBridge.recordTerminal(
                    record,
                    reason: reason,
                    dataRoot: dataRoot
                )
            }
        )
        let executor = WorkshopCompiledProcedureInvocationExecutor(
            runner: runner,
            expectedExecutionID: executionID,
            expectedContract: planner.contract,
            submitAndExecute: { _ in
                let submission = try await WorkshopDirectedTaskSubmitter(
                    dataRoot: dataRoot,
                    runner: runner
                ).submit(spec: WorkshopExecutionSpec(
                    title: "Approved compiled local file copy",
                    objective: "Execute the locally reviewed deterministic workspace file-copy procedure.",
                    triggerSource: "manual",
                    trustRequired: "none"
                ))
                guard submission.executionId == executionID else {
                    throw WorkshopCompiledProcedureRuntimeError.queueIdentityDiverged
                }
                return try await Self.executeOrAwaitCanonicalProcedure(
                    executionID: executionID,
                    runner: runner,
                    loop: loop
                )
            }
        )
        let context = ProcedureDryRunContext(
            invocationMode: .manual,
            taskFamily: planner.contract.taskFamily,
            inputClass: planner.contract.inputClass,
            parameterSchemaIdentity: planner.contract.parameterSchemaIdentity,
            authorityClass: planner.contract.authorityClass,
            requestedExternalEffectClass: "local_control",
            currentState: nil,
            nextRuleIndex: 0,
            trustCenterAllowed: true,
            preconditionResults: Dictionary(
                uniqueKeysWithValues: artifact.safety.requiredPreconditions.map { ($0, true) }
            ),
            canonicalApprovalOwnerRechecked: artifact.safety.canonicalApprovalOwner == nil,
            cancellationRequested: false
        )
        let receipt: ProcedureInvocationReceipt
        switch selection {
        case .manual:
            receipt = try await store.invokeManual(
                artifactID: artifact.id,
                opaqueInputReference: opaqueExecutionIdentity,
                context: context,
                executor: executor
            )
        case .automaticExact:
            receipt = try await store.invokeAutomaticExact(
                procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                implementationIdentity:
                    WorkshopCompiledLocalFileCopyPlanner.implementationIdentity,
                expectedArtifactID: artifact.id,
                opaqueInputReference: opaqueExecutionIdentity,
                context: context,
                executor: executor
            )
        }
        guard let finalRecord = await runner.getWorkshopExecution(executionID) else {
            throw WorkshopCompiledProcedureRuntimeError.canonicalRecordMissing
        }
        let deskAlias: String? = if let handle = finalRecord.deskHandle,
                                    let deskState = try? await SwiftNativeDeskStore(
                                        dataRoot: dataRoot
                                    ).liveState() {
            deskState.items.first(where: { $0.handle == handle })?.alias
        } else {
            nil
        }
        let outcome = WorkshopCompiledProcedureInvocationOutcome(
            artifact: artifact,
            receipt: receipt,
            execution: finalRecord,
            executionID: executionID,
            opaqueExecutionIdentity: opaqueExecutionIdentity,
            deskAlias: deskAlias
        )
        if receipt.verified {
            // This is an event consequence, not background polling. Await it
            // so the terminal canonical receipt cannot outrun and lose its
            // one-shot activation-review handoff. Custom/test roots return at
            // the coordinator's first guard; once active, production returns
            // after one checked pointer lookup.
            await WorkshopProcedureExactActivationCoordinator
                .reconcileLocalFileCopyIfQualified(dataRoot: dataRoot)
        }
        return outcome
    }

    /// HARD deadline on the canonical terminal observation below.
    ///
    /// fix-locked-unbounded-wait (2026-08-02): this observation runs INSIDE
    /// `ProcedureArtifactStore.invoke`'s `withFileLock(invocations.jsonl)` —
    /// an untimed cross-process `LOCK_EX`. With three Workshop executions already
    /// running, `claim` returns nil, `start` throws, and the wait below used to
    /// be unbounded: the record stayed `queued`, nothing ever wrote it again,
    /// and EVERY procedure invocation in EVERY process wedged behind the flock.
    /// One hang became a system-wide wedge. The deadline converts that into one
    /// typed, logged, per-caller failure.
    /// Companion rule (design doc C-2): no unbounded wait under a file lock.
    static var canonicalObservationTimeoutSeconds: TimeInterval {
        BoundedWait.seconds(
            fromEnv: "NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS",
            fallback: 300
        )
    }

    /// Internal (not private) so the bounded-observation test can drive it
    /// directly: the whole point of the deadline is that this call RETURNS.
    static func executeOrAwaitCanonicalProcedure(
        executionID: String,
        runner: SwiftNativeWorkshopRunner,
        loop: WorkshopExecutorLoop
    ) async throws -> WorkshopExecutionRecord {
        do {
            return try await loop.start(executionId: executionID)
        } catch let error as WorkshopExecutionError {
            // NARROW on purpose: the ONLY tolerated failure is losing the
            // queued→running CAS to the resident executor (a typed
            // `invalidRequest` refusal) — it is still the same canonical record
            // caused by this invocation, so we fall through and observe it.
            // The old blanket `catch {}` also swallowed CancellationError and
            // every real dispatch/IO failure, so a cancelled or broken start
            // became an unbounded wait under the invocation flock instead of an
            // error. Anything else rethrows.
            guard case .invalidRequest = error else { throw error }
        }
        let terminal: Set<String> = [
            "completed", "done", "succeeded", "failed", "cancelled", "canceled",
        ]
        if let current = await runner.getWorkshopExecution(executionID),
           terminal.contains(current.status.lowercased()) {
            return current
        }
        let timeout = canonicalObservationTimeoutSeconds
        return try await BoundedWait.run(
            seconds: timeout,
            reason: "canonical Workshop terminal record \(executionID)"
        ) {
            let changes = FileChangeEvents(paths: [runner.executionRecordPath(executionID)])
            defer { changes.cancel() }
            // Close the registration race without a timer or poll.
            if let current = await runner.getWorkshopExecution(executionID),
               terminal.contains(current.status.lowercased()) {
                return current
            }
            for await _ in changes.stream {
                try Task.checkCancellation()
                if let current = await runner.getWorkshopExecution(executionID),
                   terminal.contains(current.status.lowercased()) {
                    return current
                }
            }
            throw WorkshopCompiledProcedureRuntimeError.canonicalObservationEnded
        }
    }
}

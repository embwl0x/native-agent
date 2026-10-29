import Foundation
import NativeAgentShared
import os
import PersistenceCore
import NativeAgentCore
import Desk
import TrustCenter
import MacIntegration
import ToolRegistry
import ChatToolParsing
// Blueprint: | `WorkshopExecution+Steps.swift` | WorkshopExecutorLoop step progression, approval gating, dispatch and declared-read coverage |

extension WorkshopExecutorLoop {
    func runClaimedWorkshopExecution(_ claimed: WorkshopExecutionRecord) async {
        let executionId = claimed.id
        do {
            // Publish started only after the queued-to-running claim.
            try await appendTimelineLocked(
                .object(["event": .string("started"), "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now()))]),
                executionId: executionId
            )
            try await runSteps(executionId: executionId)
        } catch is CancellationError {
            // Parent task cancelled (pass timeout, app shutdown, or loop
            // teardown). Release only this still-running claim so the next
            // drain in the SAME process can reclaim it. A concurrent explicit
            // user cancel wins the CAS and remains terminal.
            await releaseClaimAfterInterruption(executionId)
            return
        } catch {
            // A concurrent cancellation wins over this failed-state transition.
            ModuleLog(subsystem: "com.nativeagent.workshop", category: "executor")(
                "Workshop execution error \(executionId): \(error)", level: .error)
            let failedWrite = try? await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.status = "failed"
                rec.terminalReason = String(describing: error)
                rec.currentStepId = ""
            }
            guard failedWrite?.applied == true else { return }
            try? await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string(String(describing: error)),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(failedWrite?.record, reason: String(describing: error))
        }
    }

    func releaseClaimAfterInterruption(
        _ executionId: String,
        reason: String = "parent_task_cancelled",
        outcome: WorkshopStepOutcome? = nil
    ) async {
        // Await one uncancelled cleanup task: the caller's cancellation must
        // not abort a contended file-lock acquisition and strand the claim.
        await Task {
            let released = try? await casMutateWorkshopExecution(executionId, require: ["running"]) { record in
                if record.currentStepId.isEmpty {
                    record.status = "queued"
                } else {
                    record.status = "blocked_on_reconciliation"
                    var evidence: [String: JSONValue] = ["error": .string("interrupted_step_outcome_unknown")]
                    if let outcome, record.currentStepId == outcome.stepId {
                        evidence["step_outcome"] = outcome.toJSON()
                    }
                    record.result = .object(evidence)
                }
            }
            guard let released else {
                Self.logger("execution claim reconciliation failed for \(executionId)", level: .error)
                return
            }
            guard released.applied else { return }
            try? await appendTimelineLocked(
                .object([
                    "event": .string("execution_interrupted"),
                    "reason": .string(reason),
                    "status": .string(released.record?.status ?? "blocked_on_reconciliation"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            Self.logger("interrupted execution claim for \(executionId): \(released.record?.status ?? "unknown")", level: .default)
        }.value
    }

    /// Traverse steps without a durable completed outcome; outcome commit owns transitions.
    func runSteps(executionId: String) async throws {
        guard let planSource = try await getRecord(executionId) else { return }
        try SwiftNativeWorkshopRunner.validateStepIDs(planSource.plan)
        // A parent/pass cancellation may requeue after earlier steps committed.
        // Their outcomes and receipts are durable, so a later claim skips them
        // instead of replaying side effects or double-counting completion.
        let durablyCompletedStepIDs = Set(planSource.stepsCompleted.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let stepID)? = object["step_id"],
                  case .string(let status)? = object["status"],
                  !["failed", "cancelled", "blocked_on_approval", "blocked_on_reconciliation"].contains(status) else {
                return nil
            }
            return stepID
        })
        for stepJSON in planSource.plan {
            try Task.checkCancellation()
            let step = stepJSON
            if durablyCompletedStepIDs.contains(step.id) { continue }
            if try await cancelWithDesk(executionId) { return }
            // Claim under the record lock so a concurrent cancellation wins.
            let stepClaim = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.currentStepId = step.id
            }
            guard stepClaim.applied, let execution = stepClaim.record else { return }
            let outcome = await executeStep(execution: execution, step: step)
            // dispatchStep maps a child CancellationError to a value. When the
            // parent/pass is also cancelled, that synthetic outcome means no
            // completed result crossed the boundary: release the claim without
            // fabricating a terminal user cancellation or a cancelled receipt.
            // A non-cancelled outcome may represent a side effect that ignored
            // cancellation and completed successfully, so it MUST commit below
            // before the parent cancellation is observed.
            if Task.isCancelled && outcome.status == "cancelled" {
                throw CancellationError()
            }
            guard let saved = try await commitStepOutcome(executionId, outcome: outcome) else { return }
            guard saved.status == "running" else { return }
            try Task.checkCancellation()
        }
        if try await cancelWithDesk(executionId) { return }
        // Complete under the record lock; cancellation wins and declared outputs are enforced.
        let verificationCheckedAt = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let completedWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
            rec.currentStepId = ""
            let verification = Self.verifyCompletedOutcome(
                rec,
                checkedAt: verificationCheckedAt
            )
            rec.verification = verification
            if verification.status == .failed {
                rec.status = "failed"
                rec.terminalReason = "verification_failed: \(verification.detail)"
                rec.result = .object([
                    "error": .string("verification_failed"),
                    "detail": .string(verification.detail),
                ])
            } else {
                rec.status = "completed"
                rec.terminalReason = nil
                if !rec.stepsCompleted.isEmpty {
                    let snapshot = rec
                    rec.result = Self.extractWorkshopExecutionResult(snapshot)
                }
            }
        }
        guard completedWrite.applied, let terminalRecord = completedWrite.record else { return }
        if terminalRecord.status == "failed" {
            let detail: String = {
                if case .object(let o) = terminalRecord.result,
                   case .string(let d)? = o["detail"] { return d }
                return "outcome verification failed"
            }()
            try await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string("verification_failed: \(detail)"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(completedWrite.record, reason: "verification_failed: \(detail)")
            return
        }
        try await appendTimelineLocked(
            .object(["event": .string("completed"), "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now()))]),
            executionId: executionId
        )
        await emitTerminalEvent(completedWrite.record, reason: nil)
    }

    // MARK: step execution

    /// Step kinds that are a model turn, not a tool call; their own tool calls
    /// pass the gated chain one by one.
    static let llmStepKinds: Set<String> = ["chat.synthesize", "llm", "report"]

    private func executeStep(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep) async -> WorkshopStepOutcome {
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        // Approval gate: the permission law answers this step's tool as it
        // answers chat, so a step it asks for waits on a card here, a
        // destructive one even under Full Mac. Below Full Mac the execution's
        // trustRequired and a step's own needs_approval also ask; under
        // wide-open trust stepApprovalEnforced() is false and they do not.
        // Hard domain/tool refusals still happen in the injected dispatcher at
        // effect time.
        let enforceStepAutonomy = await stepApprovalEnforced()
        var law = "auto"
        // The call that actually runs: a folded door action is its tool, as
        // the gate resolves it. It is judged, carded and replayed as itself.
        let call = Self.resolvedStepCall(step, execution: execution)
        if !Self.llmStepKinds.contains(step.toolOrAction) {
            do {
                law = try await SwiftNativeTrustCenter(dataRoot: root).autonomyLevel(forTool: call.tool, input: call.args.objectValue ?? [:])
            } catch {
                return WorkshopStepOutcome(stepId: step.id, status: "failed",
                    error: "Trust could not be read, so \(step.toolOrAction) did not run: \(error.localizedDescription)", executedAt: nowStr)
            }
        }
        if ["blocked", "deny"].contains(law) {
            return WorkshopStepOutcome(stepId: step.id, status: "failed",
                error: "Trust refuses \(step.toolOrAction) in the owner's current posture; nothing ran.", executedAt: nowStr)
        }
        let needsApproval = law != "auto" || enforceStepAutonomy && (execution.trustRequired != "none" || step.autonomy == "needs_approval")
        if needsApproval {
            // A switch User turned off refuses before any card, as the chat gate does.
            do {
                if try await deskCanceled(execution) {
                    return WorkshopStepOutcome(stepId: step.id, status: "cancelled", error: "desk_item_canceled", executedAt: nowStr)
                }
                if let refusal = try await MacIntegrationGates.refusal(tool: ToolNameAliases.canonical(call.tool), dataRoot: root) {
                    return WorkshopStepOutcome(stepId: step.id, status: "failed", error: refusal, executedAt: nowStr)
                }
            } catch {
                return WorkshopStepOutcome(stepId: step.id, status: "failed",
                    error: "Mac Integration could not be read, so \(step.toolOrAction) did not run: \(error.localizedDescription)", executedAt: nowStr)
            }
            guard let stageApproval else {
                // An approval that cannot be filed fails the step.
                return WorkshopStepOutcome(
                    stepId: step.id, status: "failed",
                    error: "approval required but no approval stager is wired",
                    executedAt: nowStr
                )
            }
            let request = WorkshopStepApprovalRequest(
                executionId: execution.id,
                stepId: step.id,
                taskTitle: execution.title,
                actionDescription: step.description,
                title: "Workshop step approval: \(step.description)",
                tool: call.tool,
                reason: "Workshop trust=\(execution.trustRequired); step autonomy=\(step.autonomy); tool=\(call.tool)",
                args: call.args,
                sourceArgs: call.sourceArgs
            )
            guard let approvalId = await stageApproval(request) else {
                return WorkshopStepOutcome(
                    stepId: step.id, status: "failed",
                    error: "approval staging failed",
                    executedAt: nowStr
                )
            }
            // The caller emits the blocked event only after its status CAS wins.
            return WorkshopStepOutcome(
                stepId: step.id, status: "blocked_on_approval",
                approvalId: approvalId, executedAt: nowStr
            )
        }
        return await dispatchStep(execution: execution, step: step)
    }

    /// Dispatch and verification resolve aliases and step references identically.
    static func resolvedStepCall(_ step: WorkshopExecutionStep, execution: WorkshopExecutionRecord,
                                 resolveReferences: Bool = true) -> (tool: String, args: JSONValue, sourceArgs: JSONValue, readOnly: Bool) {
        let args = resolveReferences ? Self.resolveStepReferences(in: step.args, execution: execution) : step.args
        guard case .object(let fields) = args else { return (step.toolOrAction, args, args, false) }
        let call = ToolNameAliases.ranCall(step.toolOrAction, input: fields)
        let readOnly = AppActionBinding.action(tool: call.tool, input: call.input)?.read == true
            || PermissionLaw.toolClass(call.tool, input: call.input) == .read
        return (call.tool, .object(call.input), args, readOnly)
    }

    func dispatchStep(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep, approvalId: String? = nil) async -> WorkshopStepOutcome {
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        guard await executionAllowed() else {
            return WorkshopStepOutcome(stepId: step.id, status: "failed",
                                       error: "Workshop execution is disabled by trust policy", executedAt: nowStr)
        }
        let tool = step.toolOrAction
        if tool.isEmpty {
            return WorkshopStepOutcome(stepId: step.id, status: "failed", error: "Empty tool_or_action", executedAt: nowStr)
        }
        let call = Self.resolvedStepCall(step, execution: execution, resolveReferences: approvalId == nil)
        let readOnly = call.readOnly
        if step.optional == true && !readOnly {
            return WorkshopStepOutcome(stepId: step.id, status: "failed",
                error: "Only a declared read-only call may be optional; this step did not run.", executedAt: nowStr)
        }
        do {
            let outcome: WorkshopStepOutcome = try await raceWithCancellationWatch(execution: execution) {
                guard await self.executionAllowed() else {
                    throw WorkshopExecutionError.forbidden("Workshop execution is disabled by trust policy")
                }
                if try await self.deskCanceled(execution) { throw WorkshopExecutionCancelledDuringStep() }
                try Task.checkCancellation()
                if let schema = step.argumentSchema {
                    try WorkshopArgumentValidation.validate(call.sourceArgs, schema: schema)
                }
                let binding: WorkshopCompiledFileCopyBinding?
                if let rawBinding = execution.compiledOperationBinding {
                    binding = try JSONDecoder().decode(WorkshopCompiledFileCopyBinding.self, from: rawBinding.serializedData(pretty: false))
                    guard binding?.workspaceRootURL == NativeAgentWorkspaceRoot.resolve(dataRoot: self.root).standardizedFileURL.resolvingSymlinksInPath(),
                          case .object(let arguments) = call.sourceArgs else {
                        throw WorkshopCompiledProcedureRuntimeError.invalidToolArguments
                    }
                    try binding?.validateBeforeDispatch(tool: tool, arguments: arguments)
                } else {
                    if execution.planningProviderCallCount == 0,
                       execution.plan.map(\.toolOrAction) == ["read_file", "write_file"] {
                        throw WorkshopExecutionError.invalidRequest("compiled operation binding is missing")
                    }
                    binding = nil
                }
                switch tool {
                case "chat.synthesize", "llm", "report":
                    guard let measuredTooledLLMStep = self.measuredTooledLLMStep else {
                        throw WorkshopExecutionError.invalidRequest("no LLM closure wired for step kind '\(tool)'")
                    }
                    let prompt = try Self.buildLLMPrompt(execution: execution, step: step)
                    let completion = try await measuredTooledLLMStep(prompt)
                    let text = completion.text
                    let empty = !Self.validateSynthesizeOutput(text)
                    var output: [String: JSONValue] = [
                        "model": .string(completion.model),
                        "text": .string(text),
                        "tooled": .bool(true),
                    ]
                    if empty { output["validation"] = .string("empty_output") }
                    return WorkshopStepOutcome(
                        stepId: step.id, status: empty ? "failed" : WorkshopStepOutcome.successStatus,
                        output: .object(output), error: empty ? "empty_output" : "",
                        executedAt: SwiftNativeWorkshopRunner.isoTimestamp(self.now()),
                        providerCallCount: completion.providerCallCount,
                        removableOrchestrationProviderCallCount: completion.removableOrchestrationProviderCallCount
                    )
                default:
                    guard let toolDispatch = self.toolDispatch else {
                        // An unavailable step fails explicitly.
                        throw WorkshopExecutionError.invalidRequest("no tool dispatcher wired for step kind '\(tool)'")
                    }
                    if approvalId != nil && self.approvedToolDispatch == nil {
                        throw WorkshopExecutionError.forbidden("approved tool dispatcher unavailable")
                    }
                    // Dispatch the exact resolved arguments, including prior step evidence.
                    let result: JSONValue
                    do {
                        if let approvalId {
                            guard let approvedToolDispatch = self.approvedToolDispatch else {
                                throw WorkshopExecutionError.forbidden("approved tool dispatcher unavailable")
                            }
                            result = try await approvedToolDispatch(call.tool, call.args, approvalId)
                        } else {
                            result = try await toolDispatch(call.tool, call.args)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard readOnly else { throw error }
                        // A thrown read and a failure envelope supply the same evidence.
                        let failure = error as? ToolFailureError
                        var fields: [String: JSONValue] = [
                            "status": .string(failure?.status.rawValue ?? "failed"),
                            "error": .string(error.localizedDescription),
                        ]
                        if let code = failure?.code { fields["error_code"] = .string(code) }
                        result = .object(fields)
                    }
                    try binding?.validateAfterDispatch(tool: tool, result: result)
                    let resultState = Self.toolStepResultState(result, tool: call.tool, readOnly: readOnly, optional: step.optional == true)
                    let output: JSONValue = {
                        if case .object = result { return result }
                        return .object(["output": result])
                    }()
                    return WorkshopStepOutcome(
                        stepId: step.id, status: resultState.status, output: output,
                        error: resultState.error,
                        executedAt: SwiftNativeWorkshopRunner.isoTimestamp(self.now()),
                        providerCallCount: 0,
                        removableOrchestrationProviderCallCount: 0,
                        readCoverage: resultState.readCoverage
                    )
                }
            }
            // Timeline notes are best effort after dispatch has settled.
            await emitSynthesizeNotes(executionId: execution.id, step: step, outcome: outcome)
            return outcome
        } catch let timeout as WorkshopStepTimedOut {
            // The deadline stays selected, but any returned receipt is retained.
            // Effects and required reads fail; optional reads retain unavailability.
            let label = timeout.seconds >= 1
                ? "\(Int(timeout.seconds))s"
                : "\(Int(timeout.seconds * 1000))ms"
            return WorkshopStepOutcome(
                stepId: step.id, status: readOnly && step.optional == true ? "skipped" : "failed",
                output: timeout.returned.map { .object(["settled_outcome": $0.toJSON()]) } ?? .null,
                error: "\(call.tool) step_timeout_exceeded_\(label)" + (timeout.cause.map { ": \($0)" } ?? ""),
                executedAt: nowStr,
                providerCallCount: timeout.returned?.providerCallCount,
                removableOrchestrationProviderCallCount: timeout.returned?.removableOrchestrationProviderCallCount,
                readCoverage: readOnly ? .unavailable : nil
            )
        } catch is WorkshopExecutionCancelledDuringStep {
            return WorkshopStepOutcome(stepId: step.id, status: "cancelled", error: "execution_cancelled", executedAt: nowStr)
        } catch is CancellationError {
            // Parent task cancelled — surface as a cancelled step; the
            // caller's post-step re-read decides what sticks on disk.
            return WorkshopStepOutcome(stepId: step.id, status: "cancelled", error: "execution_cancelled", executedAt: nowStr)
        } catch {
            return WorkshopStepOutcome(stepId: step.id, status: readOnly && step.optional == true ? "skipped" : "failed",
                error: "\(call.tool): \(error)", executedAt: nowStr, readCoverage: readOnly ? .unavailable : nil)
        }
    }

    /// Shared verdicts own finality; Workshop decides whether the retained evidence permits continuation.
    static func toolStepResultState(
        _ result: JSONValue, tool: String, readOnly: Bool = false, optional: Bool = false
    ) -> (status: String, error: String, readCoverage: WorkshopReadCoverage?) {
        let object = result.objectValue ?? [:]
        let rawStatus = object["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let verdict = ChatToolOutcome.exactResultClass(result)
        var failed = [.failed, .refused, .timeout].contains(verdict)
        // Call completion is separate from the command's exit/timeout contract.
        if ["shell", "bash", "git"].contains(tool) {
            if case .int(let code)? = object["exit_code"], code != 0 { failed = true }
            if case .double(let code)? = object["exit_code"], code != 0 { failed = true }
            if object["timed_out"] == .bool(true) { failed = true }
        }
        let coverage: [String: JSONValue] = { if case .object(let fields)? = object["coverage"] { return fields }; return [:] }()
        let partial = rawStatus == "partial" || object["partial"] == .bool(true)
            || coverage["complete"] == .bool(false) || object["has_more"] == .bool(true)
            || object["truncated"] == .bool(true)
        let explanation = ["detail", "error", "reason", "message"].compactMap { object[$0]?.stringValue }.first ?? ""
        let detail = String(("\(tool) returned " + (rawStatus.isEmpty ? verdict.rawValue : "status=\(rawStatus)")
            + (explanation.isEmpty ? "" : ": \(explanation)")).prefix(2000))
        if verdict == .cancelled { return ("cancelled", detail, nil) }
        if readOnly {
            if result != .null && ((!failed && !ChatToolOutcome.saysOutcomeOpen(result)) || partial) {
                return (failed || partial ? "partial" : WorkshopStepOutcome.successStatus,
                    failed || partial ? detail : "", failed || partial ? .partial : .complete)
            }
            let absent = result == .null || ["error_code", "failure_code", "status"].contains {
                object[$0] == .string("file_not_found") || object[$0] == .string("not_found")
            }
            return (optional ? "skipped" : "failed", detail, absent ? .absent : .unavailable)
        }
        if DeskContinuation.receiptIsUnresolved(result) || (!failed && verdict == .unknown) {
            return ("blocked_on_reconciliation", "\(tool) outcome remains unresolved; inspect its retained owner receipt before continuing.", nil)
        }
        return failed || partial ? ("failed", detail, nil) : (WorkshopStepOutcome.successStatus, "", nil)
    }

    /// Record rejected synthesis output before it can be scored as succeeded.
    private func emitSynthesizeNotes(
        executionId: String, step: WorkshopExecutionStep, outcome: WorkshopStepOutcome
    ) async {
        let tool = step.toolOrAction
        guard Self.llmStepKinds.contains(tool) else { return }
        let ts = SwiftNativeWorkshopRunner.isoTimestamp(now())
        if outcome.status == "failed",
           case .object(let o) = outcome.output,
           case .string(let reason)? = o["validation"],
           reason == "empty_output" {
            try? await appendTimelineLocked(
                .object([
                    "event": .string("synthesize_validation_failed"),
                    "step_id": .string(step.id),
                    "reason": .string(reason),
                    "ts": .string(ts),
                ]),
                executionId: executionId
            )
        }
    }


}

import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Workshop and task ledger tools

extension SwiftToolDispatcher {
    // MARK: - Workshop chat lane

    /// Build a Workshop runner pointed at THIS dispatcher's data root, wiring the
    /// production planner (`SwiftNativeWorkshopPlannerLLM`) so a chat-submitted
    /// task is planned exactly like one the background executor drains. The
    /// runner is stateless w.r.t. the executor — they share the on-disk queue
    /// under `<dataRoot>/workshop/executions/`, not in-memory state. `executorAvailable`
    /// defaults TRUE (the executor port landed 2026-06-10); the runner's OWN
    /// missionPolicy gate + slot cap + per-step approval staging apply
    /// downstream, so this tool adds no new policy.
    private func workshopRunner() -> SwiftNativeWorkshopRunner {
        // TOOL-AWARE planner: inject THIS dispatcher's own tool catalog so a
        // chat-submitted execution plans against the same tools the chat loop
        // sees, not only chat.synthesize (root cause fixed 2026-06-15). Capped
        // to 40 to bound prompt size (the planner itself prefixes 30).
        SwiftNativeWorkshopRunner(
            root: dataRoot,
            planner: SwiftNativeWorkshopPlannerLLM(
                connectorActionsProvider: { [self] in
                    let schemas = (try? await listAvailableToolSchemas()) ?? []
                    return schemas.prefix(200).map { schema -> JSONValue in
                        // Append arg names so the planner fills correct args
                        // (e.g. shell needs `cmd`); `*` = required.
                        var desc = schema.description
                        if let obj = try? JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any],
                           let props = obj["properties"] as? [String: Any], !props.isEmpty {
                            let req = Set((obj["required"] as? [String]) ?? [])
                            let args = props.keys.sorted().map { req.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
                            desc = "\(desc) [args: \(args)]"
                        }
                        return JSONValue.object([
                            "id": .string(schema.name),
                            "description": .string(desc),
                        ])
                    }
                },
                lifecycleObserver: providerLifecycleObserver,
                // Ledger rows follow the runner's root — a dispatcher built on
                // a test dataRoot must not append to the live runs ledger
                // (gpt-5.5 review BLOCKING, 2026-07-02).
                runLedgerDataRoot: dataRoot)
        )
    }

    /// workshop_submit — thin shim into SwiftNativeWorkshopRunner.submit. The
    /// executor's compatibility policy gate, slot capacity, planner, and per-step
    /// approval gates ALL apply downstream; this tool adds no new policy. On a
    /// gate refusal (Workshop disabled / slots full / empty objective) we
    /// surface the runner's honest typed error as a `failed` envelope the tool
    /// loop classifies as failed (not a crash), mirroring impl_commit_memory.
    func impl_workshop_submit(input: [String: JSONValue]) async throws -> JSONValue {
        let text = try requireString(input, "text")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: workshop_submit requires non-empty 'text'"
            )
        }
        // `context` is an optional short title; default to a prefix of the
        // objective (the runner itself truncates title to 160 / objective to
        // 2000, so we only pick a sensible default here).
        let contextTitle = optionalString(input, "context")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (contextTitle?.isEmpty == false ? contextTitle! : nil)
            ?? String(text.prefix(160))

        let requestedProcedure = optionalString(input, "procedure")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedOperation = optionalString(input, "operation")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redundantExactPair = requestedProcedure == "local_file_copy_v1"
            && requestedOperation == "copy_workspace_file"
        if requestedProcedure?.isEmpty == false,
           requestedOperation?.isEmpty == false,
           !redundantExactPair {
            return .object([
                "status": .string("failed"),
                "reason": .string("operation and procedure identify conflicting routes"),
            ])
        }
        if let requestedProcedure, !requestedProcedure.isEmpty,
           requestedProcedure != "local_file_copy_v1" {
            return .object([
                "status": .string("failed"),
                "reason": .string("unsupported Workshop procedure '\(requestedProcedure)'"),
                "supported_procedures": .array([.string("local_file_copy_v1")]),
            ])
        }
        if let requestedOperation, !requestedOperation.isEmpty,
           requestedOperation != "copy_workspace_file" {
            return .object([
                "status": .string("failed"),
                "reason": .string("unsupported exact Workshop operation '\(requestedOperation)'"),
                "supported_operations": .array([.string("copy_workspace_file")]),
            ])
        }

        var procedureFallbackReason: String?
        // GPT-family structured decoders can redundantly populate both known
        // enum fields when the user names the old procedure. The sole exact
        // equivalent pair is canonicalized to the stable operation; every
        // conflicting future pair still fails before admission.
        let explicitProcedure = requestedProcedure == "local_file_copy_v1"
            && !redundantExactPair
        let exactTypedOperation = requestedOperation == "copy_workspace_file"
        if explicitProcedure || exactTypedOperation {
            let source = optionalString(input, "source")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = optionalString(input, "destination")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source, !source.isEmpty, let destination, !destination.isEmpty else {
                return .object([
                    "status": .string("failed"),
                    "reason": .string(
                        "procedure local_file_copy_v1 requires non-empty source and destination"
                    ),
                ])
            }

            let store = ProcedureArtifactStore(dataRoot: dataRoot)
            do {
                let artifact: DeclarativeProcedureArtifact?
                if exactTypedOperation {
                    artifact = try await store.loadActiveExactProcedure(
                        procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                        implementationIdentity:
                            WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
                    ).artifact
                } else {
                    let artifacts = try await store.loadInstalledArtifacts(
                        domain: "workshop_execution"
                    ).filter(WorkshopCompiledLocalFileCopyPlanner.isEligibleArtifact)
                    artifact = artifacts.count == 1 ? artifacts.first : nil
                    if artifacts.count > 1 {
                        procedureFallbackReason = "approved_artifact_ambiguous"
                    }
                }
                if let artifact {
                    let invocationKey = TurnTraceContext.turnId
                        ?? CausalTransitionEvidence.opaqueIdentity([
                            "direct-workshop-procedure",
                            Self.stringValue(input["__session_id"]) ?? "unbound",
                            source,
                            destination,
                        ].joined(separator: "|"))
                    let invocation: WorkshopCompiledLocalFileCopyInvocation
                    do {
                        invocation = try WorkshopCompiledLocalFileCopyInvocation(
                            artifact: artifact,
                            dataRoot: dataRoot,
                            sourceRelativePath: Self.procedureRelativePath(source),
                            destinationRelativePath: Self.procedureRelativePath(destination),
                            invocationKey: invocationKey,
                            store: store
                        )
                    } catch {
                        if exactTypedOperation,
                           error is WorkshopCompiledProcedurePlanError {
                            return .object([
                                "status": .string("failed"),
                                "reason": .string(error.localizedDescription),
                                "procedure": .string("local_file_copy_v1"),
                                "procedure_used": .bool(false),
                                "ordinary_fallback_submitted": .bool(false),
                            ])
                        }
                        procedureFallbackReason = "compiled_preflight_refused"
                        return try await ordinaryWorkshopSubmission(
                            title: title,
                            text: text,
                            procedureFallbackReason: procedureFallbackReason
                        )
                    }
                    do {
                        let policy: WorkshopCompiledLocalFileCopyInvocation.PolicyAllowed = {
                            [dataRoot] in
                            await Self.compiledWorkshopPolicyAllows(dataRoot: dataRoot)
                        }
                        let dispatch: WorkshopCompiledLocalFileCopyInvocation.ToolDispatch = {
                            [self] tool, arguments in
                            switch tool {
                            case "read_file":
                                return try await impl_read_file(input: arguments)
                            case "write_file":
                                return try await impl_trusted_write_file(input: arguments)
                            default:
                                throw WorkshopCompiledProcedureRuntimeError.unsupportedTool
                            }
                        }
                        let outcome = if exactTypedOperation {
                            try await invocation.invokeAutomaticExact(
                                policyAllowed: policy,
                                toolDispatch: dispatch
                            )
                        } else {
                            try await invocation.invokeManual(
                                policyAllowed: policy,
                                toolDispatch: dispatch
                            )
                        }
                        return Self.compiledWorkshopEnvelope(outcome)
                    } catch {
                        // Invocation may already own a canonical effect. Never
                        // fall through to the ordinary planner after admission
                        // and risk submitting the same work twice.
                        var failure: [String: JSONValue] = [
                            "status": .string("failed"),
                            "reason": .string(error.localizedDescription),
                            "procedure": .string("local_file_copy_v1"),
                            "procedure_used": .bool(true),
                            "ordinary_fallback_submitted": .bool(false),
                        ]
                        // Preserve the canonical correlation only if Workshop
                        // actually admitted this deterministic identity. A
                        // pre-admission policy refusal must not manufacture a
                        // motor action, while an admitted failure must remain
                        // visible to resident cognition and Outcome Tissue.
                        if let record = await workshopRunner()
                            .getWorkshopExecution(invocation.executionID) {
                            failure["id"] = .string(record.id)
                            failure["execution_status"] = .string(record.status)
                            failure["verification_status"] = record.verification
                                .map { .string($0.status.rawValue) } ?? .null
                        }
                        return .object(failure)
                    }
                }
                if procedureFallbackReason == nil {
                    procedureFallbackReason = exactTypedOperation
                        ? "exact_activation_unavailable"
                        : "approved_artifact_unavailable"
                }
            } catch {
                procedureFallbackReason = exactTypedOperation
                    ? "exact_activation_unavailable"
                    : "approved_artifact_unavailable"
            }
        }

        return try await ordinaryWorkshopSubmission(
            title: title,
            text: text,
            procedureFallbackReason: procedureFallbackReason
        )
    }

    private func ordinaryWorkshopSubmission(
        title: String,
        text: String,
        procedureFallbackReason: String?
    ) async throws -> JSONValue {
        let spec = WorkshopExecutionSpec(title: title, objective: text)
        let result: WorkshopDirectedTaskResult
        do {
            result = try await WorkshopDirectedTaskSubmitter(
                dataRoot: dataRoot,
                runner: workshopRunner()
            ).submit(spec: spec)
        } catch {
            // Honest pass-through of the runner's typed refusal/failure. The
            // Compatibility error code (forbidden / missions_busy) rides along when
            // present so the model can distinguish a policy refusal from a
            // transient busy state.
            var envelope: [String: JSONValue] = [
                "status": .string("failed"),
                "reason": .string("\(error.localizedDescription)"),
            ]
            if let workshopExecutionsError = error as? WorkshopExecutionError,
               let code = workshopExecutionsError.parityErrorCode {
                envelope["error"] = .string(code)
            }
            return .object(envelope)
        }
        var envelope: [String: JSONValue] = [
            "status": .string(result.execution.status),
            "id": .string(result.executionId),
            "desk_handle": .string(result.deskItem.handle),
            "desk_alias": .string(result.deskItem.alias),
            "execution": result.execution.toJSON(),
            "procedure_used": .bool(false),
        ]
        if let procedureFallbackReason {
            envelope["procedure_fallback"] = .string(procedureFallbackReason)
        }
        return .object(envelope)
    }

    private static func procedureRelativePath(_ raw: String) -> String {
        raw.hasPrefix("workspace/") ? String(raw.dropFirst("workspace/".count)) : raw
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func compiledWorkshopPolicyAllows(dataRoot: URL) async -> Bool {
        do {
            let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot)
                .loadTrustPolicyChecked()
            return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
        } catch {
            return false
        }
    }

    private static func compiledWorkshopEnvelope(
        _ outcome: WorkshopCompiledProcedureInvocationOutcome
    ) -> JSONValue {
        let record = outcome.execution
        let stepCounts = record.stepsCompleted.compactMap { row -> (Int, Int)? in
            guard case .object(let object) = row,
                  case .int(let provider)? = object["provider_call_count"],
                  case .int(let removable)? = object[
                    "removable_orchestration_provider_call_count"
                  ], provider >= 0, removable >= 0,
                  removable <= provider else { return nil }
            return (Int(provider), Int(removable))
        }
        let planningProvider = record.planningProviderCallCount
        let planningRemovable = record.planningRemovableOrchestrationProviderCallCount
        let exactAccounting = planningProvider.map { $0 >= 0 } == true
            && planningRemovable.map { $0 >= 0 } == true
            && planningRemovable! <= planningProvider!
            && stepCounts.count == record.stepsCompleted.count
        let totalProviderCalls = exactAccounting
            ? planningProvider! + stepCounts.reduce(0) { $0 + $1.0 }
            : nil
        let totalRemovableCalls = exactAccounting
            ? planningRemovable! + stepCounts.reduce(0) { $0 + $1.1 }
            : nil
        let verified = outcome.receipt.verified
            && outcome.receipt.authorityRechecked
            && outcome.receipt.canonicalEvidenceMatched
            && record.status == "completed"
            && record.verification?.status == .satisfied
        return .object([
            "status": .string(verified ? "completed" : "failed"),
            "execution_status": .string(record.status),
            "id": .string(outcome.executionID),
            "desk_handle": record.deskHandle.map(JSONValue.string) ?? .null,
            "desk_alias": outcome.deskAlias.map(JSONValue.string) ?? .null,
            "execution": record.toJSON(),
            "procedure": .string("local_file_copy_v1"),
            "procedure_used": .bool(true),
            "artifact_id": .string(outcome.artifact.id),
            "procedure_invocation_id": .string(outcome.receipt.invocationID),
            "procedure_verified": .bool(verified),
            "authority_rechecked": .bool(outcome.receipt.authorityRechecked),
            "canonical_evidence_matched": .bool(
                outcome.receipt.canonicalEvidenceMatched
            ),
            "planning_provider_calls": record.planningProviderCallCount
                .map { .int(Int64($0)) } ?? .null,
            "total_provider_calls": totalProviderCalls
                .map { .int(Int64($0)) } ?? .null,
            "removable_orchestration_provider_calls": totalRemovableCalls
                .map { .int(Int64($0)) } ?? .null,
            "verification_status": record.verification
                .map { .string($0.status.rawValue) } ?? .null,
            "verification_methods": .array(
                (record.verification?.methods ?? []).map(JSONValue.string)
            ),
            "automatic_selection": .bool(outcome.receipt.automaticSelection),
            "permission_authority": .bool(false),
            "ordinary_fallback_submitted": .bool(false),
        ])
    }

    /// workshop_status — read-only. No id: list active executions first, then
    /// recent history (capped at 20 by listHistory), each as a compact
    /// {id,title,status,updated_at} row. With an id: the byte-faithful execution
    /// detail (getWorkshopExecutionWireJSON) plus a step-receipts summary; an unknown id
    /// returns an honest `not_found` envelope (never a fabricated empty record).
    func impl_workshop_status(input: [String: JSONValue]) async throws -> JSONValue {
        let runner = workshopRunner()
        let id = optionalString(input, "id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Detail branch.
        if let id, !id.isEmpty {
            guard let wire = await runner.getWorkshopExecutionWireJSON(id) else {
                return .object([
                    "status": .string("not_found"),
                    "id": .string(id),
                    "reason": .string("no Workshop execution with id \(id)"),
                ])
            }
            // Step-receipts summary from the timeline (best-effort; a read
            // failure yields an empty summary, never fabricates).
            let timeline = (try? await runner.readTimeline(id)) ?? []
            let receipts = Self.workshopReceiptsSummary(timeline)
            var detail: [String: JSONValue]
            if case .object(let obj) = wire { detail = obj } else { detail = [:] }
            detail["receipts_summary"] = receipts
            return .object([
                "status": .string("ok"),
                "execution": .object(detail),
            ])
        }

        // List branch: active (live) first, then recent history.
        let active = await runner.listActive()
        let history = await runner.listHistory()
        func row(_ r: WorkshopExecutionRecord) -> JSONValue {
            .object([
                "id": .string(r.id),
                "title": .string(r.title),
                "status": .string(r.status),
                "updated_at": .string(r.updatedAt),
                "created_at": .string(r.createdAt),
            ])
        }
        return .object([
            "status": .string("ok"),
            "active": .array(active.map(row)),
            "recent": .array(history.map(row)),
        ])
    }

    /// task_ledger_post — append one event to the cross-agent task ledger
    /// (`<dataRoot>/orchestration/task_ledger.jsonl`) under the shared flock,
    /// cap to newest-5000, and recompact the derived state in the same lock.
    /// This is Agent's WRITE surface into the same feed Claude/Codex append to
    /// via script/task_ledger.sh -> Swift task-ledger. The actor is pinned to `agent` — the in-app
    /// chat tool can only ever post AS Agent (an unattended caller cannot
    /// impersonate Claude/Codex/the user through chat). Medium-write; available on
    /// the claude/codex bridge as of the user's 2026-06-13 "open the bridges" call
    /// (the actor pin to `agent` is the integrity boundary, not a bridge deny).
    func impl_task_ledger_post(input: [String: JSONValue]) async throws -> JSONValue {
        let kindRaw = try requireString(input, "kind")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = TaskLedgerKind(rawValue: kindRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "task_ledger_post: unknown kind '\(kindRaw)' (expected one of \(TaskLedgerKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        // taskId is required for follow-up events; for `created` we mint one
        // when omitted so the model can open a fresh task without a round-trip.
        let providedTaskId = optionalString(input, "task_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let taskId: String
        if let providedTaskId, !providedTaskId.isEmpty {
            taskId = providedTaskId
        } else if kind == .created {
            taskId = UUID().uuidString
        } else {
            throw AutonomyGateError.toolDenied(
                reason: "task_ledger_post: task_id is required for kind '\(kind.rawValue)' (only 'created' may omit it)"
            )
        }
        let title = optionalString(input, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = optionalString(input, "note")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var refs: [String] = []
        if case .array(let arr)? = input["refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s.trimmingCharacters(in: .whitespacesAndNewlines) } else { return nil } }
                .filter { !$0.isEmpty }
        }

        let event = TaskLedgerEvent(
            taskId: taskId,
            actor: .assistant,
            kind: kind,
            title: (title?.isEmpty == false) ? title : nil,
            note: (note?.isEmpty == false) ? note : nil,
            refs: refs
        )
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        do {
            let written = try await ledger.append(event)
            return .object([
                "status": .string("ok"),
                "event": written.toJSON(),
                "task_id": .string(written.taskId),
            ])
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error.localizedDescription)"),
            ])
        }
    }

    /// task_ledger_list — read-only view of the derived task states (newest
    /// updated first). With `task_id`: that one task's full event timeline.
    /// Without: the compacted per-task summary. `include_done` (default false)
    /// folds terminal tasks back in. Pure read; bridge-ALLOWED.
    func impl_task_ledger_list(input: [String: JSONValue]) async throws -> JSONValue {
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        let id = optionalString(input, "task_id")?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detail branch: one task's events.
        if let id, !id.isEmpty {
            let events = (try? await ledger.readEventsUnlocked()) ?? []
            let forTask = events.filter { $0.taskId == id }
            if forTask.isEmpty {
                return .object([
                    "status": .string("not_found"),
                    "task_id": .string(id),
                    "reason": .string("no task with id \(id)"),
                ])
            }
            let state = SwiftNativeTaskLedger.compact(forTask).first
            return .object([
                "status": .string("ok"),
                "task": state?.toJSON() ?? .null,
                "events": .array(forTask.map { $0.toJSON() }),
            ])
        }

        // List branch: compacted per-task summary.
        let includeDone: Bool
        switch input["include_done"] {
        case .some(.bool(let b)): includeDone = b
        case .some(.string(let s)): includeDone = ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: includeDone = false
        }
        let tasks = (try? await ledger.listTasks(includeTerminal: includeDone)) ?? []
        return .object([
            "status": .string("ok"),
            "tasks": .array(tasks.map { $0.toJSON() }),
        ])
    }

    /// Compact step-receipts summary derived from a Workshop execution's timeline events.
    /// Counts the terminal-ish event kinds the executor writes so the model can
    /// see progress without parsing the full timeline. Tolerant of unknown
    /// shapes (skips events without a string `event`/`type`).
    static func workshopReceiptsSummary(_ timeline: [JSONValue]) -> JSONValue {
        var counts: [String: Int] = [:]
        var lastEvent: String?
        for entry in timeline {
            guard case .object(let obj) = entry else { continue }
            let kind: String?
            if case .string(let e)? = obj["event"] { kind = e }
            else if case .string(let t)? = obj["type"] { kind = t }
            else { kind = nil }
            if let kind {
                counts[kind, default: 0] += 1
                lastEvent = kind
            }
        }
        var summary: [String: JSONValue] = [
            "event_count": .int(Int64(timeline.count)),
            "events_by_kind": .object(counts.mapValues { .int(Int64($0)) }),
        ]
        if let lastEvent { summary["last_event"] = .string(lastEvent) }
        return .object(summary)
    }

    /// Number coercion for confidence/importance (accepts double, int, or a
}

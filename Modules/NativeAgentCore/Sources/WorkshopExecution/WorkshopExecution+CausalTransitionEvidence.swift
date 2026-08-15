import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeWorkshopRunner: MotorActionReadModelProviding {}

/// Pure payload-free interpretation of an already-canonical Workshop plan.
/// It classifies schema, shape, authority, and effect classes without
/// fabricating timeline events or implying that any step executed.
public struct WorkshopProcedureContractProjection: Sendable, Equatable {
    public let taskFamily: String
    public let inputClass: String
    public let parameterSchemaClass: String
    public let parameterSchemaIdentity: String
    public let procedureShapeIdentity: String
    public let authorityClass: String
    public let externalEffectClasses: [String]
}

public extension SwiftNativeWorkshopRunner {
    nonisolated static func procedureContractProjection(
        record: WorkshopExecutionRecord
    ) -> WorkshopProcedureContractProjection {
        let schemaSource = record.plan.prefix(16).map {
            procedureArgumentShape($0.args)
        }.joined(separator: ">")
        // GRDB is transitively visible in this module (via MemoryV2), and its
        // `SQL` string-interpolation + `joined(separator:)` overloads can win
        // type inference over plain String for an unannotated interpolating
        // closure. That hashes an unstable SQL debug description (it embeds a
        // per-process context address) instead of the token string, making the
        // identity nondeterministic. The explicit `-> String` return annotation
        // is load-bearing; the pinned-identity test fences the exact digest.
        let shapeSource = record.plan.prefix(16).map { step -> String in
            let tool = procedureToken(step.toolOrAction, maximum: 80) ?? "unknown"
            let autonomy = procedureToken(step.autonomy, maximum: 40) ?? "unknown"
            return "\(tool)|\(autonomy)"
        }.joined(separator: ">")
        let authorityClass: String = switch record.trustRequired {
        case "none", "draft_auto": "low_risk"
        case "send_approval": "confirm_required"
        default: "high_risk"
        }
        let inputClass: String = {
            if record.triggerSource == "manual" { return "manual" }
            if record.triggerSource.hasPrefix("trigger:") { return "scheduled" }
            if record.triggerSource == "golden_eval" { return "evaluation" }
            return "background"
        }()
        let effects = Set(record.plan.prefix(16).map { step in
            procedureExternalEffectClass(event: "step_completed", tool: step.toolOrAction)
        }).union(["local_control"])
        return WorkshopProcedureContractProjection(
            taskFamily: "workshop.routine",
            inputClass: inputClass,
            parameterSchemaClass: "typed_step_arguments_v1",
            parameterSchemaIdentity: CausalTransitionEvidence.opaqueIdentity(
                "workshop_schema_v1|\(schemaSource)"
            ),
            procedureShapeIdentity: CausalTransitionEvidence.opaqueIdentity(
                "workshop_shape_v1|\(shapeSource)"
            ),
            authorityClass: authorityClass,
            externalEffectClasses: effects.sorted()
        )
    }

    /// Shared motor-tissue projection over the canonical execution record.
    /// A Workshop `completed` record is deliberately marked `unverified`:
    /// Workshop currently proves executor completion, not generic real-world
    /// verification of every declared output.
    func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        guard let record = await getWorkshopExecution(actionId) else { return nil }
        return Self.motorActionReadModel(record: record)
    }

    /// Pure form used when an owner has already emitted the exact canonical
    /// record. Keeping the mapping here prevents app/runtime observers from
    /// growing a second interpretation of Workshop terminal state.
    nonisolated static func motorActionReadModel(
        record: WorkshopExecutionRecord
    ) -> MotorActionReadModel {
        let normalized = record.status.lowercased()
        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let expectedEvidence: String?
        switch normalized {
        case "queued":
            phase = .ready
            verification = .notStarted
            expectedEvidence = "execution_start"
        case "running":
            phase = .running
            verification = .notStarted
            expectedEvidence = "step_or_terminal_outcome"
        case "blocked_on_approval":
            phase = .awaitingApproval
            verification = .notStarted
            expectedEvidence = "approval_resolution"
        case "completed", "done", "succeeded":
            phase = .succeeded
            switch record.verification?.status {
            case .satisfied:
                verification = .satisfied
                expectedEvidence = nil
            case .failed:
                // Compatibility guard: a newly written failed verification
                // should make the canonical execution failed, but never hide
                // contradictory persisted evidence on an older/manual record.
                verification = .failed
                expectedEvidence = "domain_recovery"
            case .unverified, nil:
                verification = .unverified
                expectedEvidence = "domain_verification"
            }
        case "failed":
            phase = .failed
            verification = .failed
            expectedEvidence = nil
        case "cancelled", "canceled":
            phase = .cancelled
            verification = .notRequired
            expectedEvidence = nil
        default:
            phase = .unknown
            verification = .unknown
            expectedEvidence = "domain_recovery"
        }
        return MotorActionReadModel(
            domain: "workshop_execution",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(record.id),
            phase: phase,
            domainState: record.status,
            verification: verification,
            expectedNextEvidence: expectedEvidence,
            updatedAt: record.updatedAt,
            cancellationIdentity: CausalTransitionEvidence.opaqueIdentity(record.id)
        )
    }

    /// Pure, payload-free projection over an already-read Workshop timeline.
    /// The timeline and execution record remain canonical; this creates no file,
    /// receipt, action, prompt context, or authority.
    nonisolated static func causalTransitionEvidence(
        executionId: String,
        timeline: [JSONValue],
        record: WorkshopExecutionRecord? = nil,
        limit: Int = 512
    ) -> [CausalTransitionEvidence] {
        let boundedLimit = max(0, min(limit, 2_048))
        guard boundedLimit > 0 else { return [] }
        let itemIdentity = CausalTransitionEvidence.opaqueIdentity(executionId)
        var priorState: String?
        var priorOperationID: String?
        var result: [CausalTransitionEvidence] = []
        let planByStepID = Dictionary(
            (record?.plan ?? []).prefix(16).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let contract = record.map(procedureContractProjection)

        for (index, value) in timeline.enumerated() {
            guard case .object(let row) = value,
                  case .string(let event)? = row["event"] else { continue }
            let occurredAt: String
            if case .string(let timestamp)? = row["ts"] { occurredAt = timestamp }
            else { occurredAt = "unknown" }
            let afterState = workshopState(after: event, prior: priorState)
            let step: WorkshopExecutionStep? = {
                guard case .string(let stepID)? = row["step_id"] else { return nil }
                return planByStepID[stepID]
            }()
            let operationID = CausalTransitionEvidence.opaqueIdentity(
                "\(executionId)|\(index)|\(event)|\(occurredAt)"
            )
            let outcome: String
            if priorState == nil, afterState != nil { outcome = "item_created" }
            else if priorState != afterState { outcome = "state_changed" }
            else { outcome = "state_unchanged" }
            let terminalClass: String? = {
                switch event {
                case "completed":
                    return record?.verification?.status == .satisfied
                        ? "verified_success" : "unverified_success"
                case "failed": return "verified_failure"
                case "cancelled": return "cancelled"
                default: return nil
                }
            }()
            let verificationClass: String? = {
                switch event {
                case "completed":
                    switch record?.verification?.status {
                    case .satisfied: return "verified"
                    case .failed: return "failed"
                    case .unverified, nil: return "unverified"
                    }
                case "failed": return "verified"
                case "cancelled": return "not_applicable"
                case "step_completed", "step_blocked_on_approval", "approval_decision":
                    return "observed"
                default: return "unknown"
                }
            }()
            let latencyMilliseconds: Int? = {
                guard terminalClass != nil,
                      let createdAt = record?.createdAt,
                      let start = WorkshopOutcomeScoreboard.parseTimestamp(createdAt),
                      let end = WorkshopOutcomeScoreboard.parseTimestamp(occurredAt),
                      end >= start else { return nil }
                return Int(min(Double(Int.max), end.timeIntervalSince(start) * 1_000))
            }()
            // Publish cumulative accounting once, on the terminal row. Step
            // rows already describe execution shape; repeating totals there
            // would double-count during trajectory extraction. Any legacy or
            // injected seam missing an exact count makes the whole total nil.
            let providerAccounting = terminalClass == nil
                ? nil
                : record.flatMap(workshopProviderAccounting)
            result.append(CausalTransitionEvidence(
                domain: "workshop_execution",
                operationId: operationID,
                occurredAt: occurredAt,
                itemIdentity: itemIdentity,
                kind: recognizedWorkshopEvent(event),
                beforeState: priorState,
                afterState: afterState,
                expectedNextEvidence: expectedWorkshopEvidence(after: event),
                outcome: outcome,
                trajectoryID: itemIdentity,
                parentOperationID: priorOperationID,
                sequenceNumber: index,
                motorPhase: workshopMotorPhase(afterState),
                verificationClass: verificationClass,
                authorityClass: contract?.authorityClass,
                deadlineClass: nil,
                terminalClass: terminalClass,
                completenessClass: terminalClass == nil ? "observed" : "complete",
                taskFamily: contract?.taskFamily,
                inputClass: contract?.inputClass,
                inputInstanceIdentity: record == nil ? nil : itemIdentity,
                parameterSchemaClass: contract?.parameterSchemaClass,
                parameterSchemaIdentity: contract?.parameterSchemaIdentity,
                procedureShapeIdentity: contract?.procedureShapeIdentity,
                actionKind: procedureActionKind(event: event, tool: step?.toolOrAction),
                evidenceKind: procedureEvidenceKind(event: event, row: row),
                checkpointClass: procedureCheckpointClass(event: event),
                retryClass: event == "execution_interrupted" ? "deterministic_resume" : nil,
                retryCount: terminalClass == nil ? nil : record?.rerunCount,
                cancellationClass: event == "cancelled" ? "canonical_user_cancellation" : nil,
                externalEffectClass: procedureExternalEffectClass(
                    event: event,
                    tool: step?.toolOrAction
                ),
                latencyMilliseconds: latencyMilliseconds,
                providerCallCount: providerAccounting?.providerCallCount,
                toolCallCount: event == "step_completed" ? 1 : nil,
                providerCostMicros: nil,
                toolCostMicros: nil,
                removableOrchestrationProviderCallCount:
                    providerAccounting?.removableOrchestrationProviderCallCount
            ))
            priorState = afterState
            priorOperationID = operationID
        }
        return Array(result.suffix(boundedLimit))
    }

    private nonisolated static func workshopProviderAccounting(
        _ record: WorkshopExecutionRecord
    ) -> (providerCallCount: Int, removableOrchestrationProviderCallCount: Int)? {
        guard let planning = record.planningProviderCallCount,
              let planningRemovable = record.planningRemovableOrchestrationProviderCallCount,
              planning >= 0,
              planningRemovable >= 0,
              planningRemovable <= planning else { return nil }
        var providerTotal = planning
        var removableTotal = planningRemovable
        for value in record.stepsCompleted {
            guard case .object(let object) = value,
                  case .int(let provider)? = object["provider_call_count"],
                  case .int(let removable)? =
                    object["removable_orchestration_provider_call_count"],
                  provider >= 0,
                  removable >= 0,
                  removable <= provider else { return nil }
            let (nextProvider, providerOverflow) = providerTotal.addingReportingOverflow(Int(provider))
            let (nextRemovable, removableOverflow) =
                removableTotal.addingReportingOverflow(Int(removable))
            guard !providerOverflow, !removableOverflow else { return nil }
            providerTotal = nextProvider
            removableTotal = nextRemovable
        }
        guard removableTotal <= providerTotal else { return nil }
        return (providerTotal, removableTotal)
    }

    private nonisolated static func workshopState(after event: String, prior: String?) -> String? {
        switch event {
        case "enqueued": return "queued"
        case "started", "step_completed", "approval_decision": return "running"
        case "step_blocked_on_approval": return "blocked_on_approval"
        case "completed": return "completed"
        case "failed": return "failed"
        case "cancelled": return "cancelled"
        case "execution_interrupted": return "queued"
        default: return prior
        }
    }

    private nonisolated static func recognizedWorkshopEvent(_ event: String) -> String {
        let recognized: Set<String> = [
            "planner_fallback", "enqueued", "started", "step_completed",
            "step_blocked_on_approval", "approval_decision", "approval_decision_ignored",
            "execution_interrupted", "synthesize_untooled",
            "synthesize_validation_failed", "completed", "failed", "cancelled",
        ]
        return recognized.contains(event) ? event : "domain_specific"
    }

    private nonisolated static func expectedWorkshopEvidence(after event: String) -> String? {
        switch event {
        case "enqueued", "execution_interrupted": return "execution_start"
        case "started", "step_completed", "approval_decision": return "step_or_terminal_outcome"
        case "step_blocked_on_approval": return "approval_resolution"
        default: return nil
        }
    }

    private nonisolated static func workshopMotorPhase(_ state: String?) -> String? {
        switch state {
        case "queued": return MotorActionPhase.ready.rawValue
        case "running": return MotorActionPhase.running.rawValue
        case "blocked_on_approval": return MotorActionPhase.awaitingApproval.rawValue
        case "completed": return MotorActionPhase.succeeded.rawValue
        case "failed": return MotorActionPhase.failed.rawValue
        case "cancelled": return MotorActionPhase.cancelled.rawValue
        default: return nil
        }
    }

    private nonisolated static func procedureActionKind(event: String, tool: String?) -> String? {
        switch event {
        case "enqueued": return "queue_admission"
        case "started": return "execute_plan"
        case "step_completed":
            guard let tool = procedureToken(tool, maximum: 80) else { return nil }
            return "tool:\(tool)"
        case "step_blocked_on_approval": return "approval_stage"
        case "approval_decision": return "approval_resume"
        case "execution_interrupted": return "release_claim"
        case "cancelled": return "cancel"
        default: return nil
        }
    }

    private nonisolated static func procedureEvidenceKind(
        event: String,
        row: [String: JSONValue]
    ) -> String? {
        switch event {
        case "enqueued": return "queue_receipt"
        case "started": return "execution_claim"
        case "step_completed":
            if case .string(let rawStatus)? = row["status"],
               let status = procedureToken(rawStatus, maximum: 40),
               ["succeeded", "failed", "cancelled", "blocked_on_approval", "stubbed"]
                .contains(status) {
                return "step_receipt:\(status)"
            }
            return "step_receipt:unknown"
        case "step_blocked_on_approval": return "approval_request"
        case "approval_decision": return "approval_decision"
        case "execution_interrupted": return "claim_release_receipt"
        case "completed": return "domain_verification"
        case "failed": return "terminal_failure"
        case "cancelled": return "cancellation_receipt"
        default: return "domain_event"
        }
    }

    private nonisolated static func procedureCheckpointClass(event: String) -> String? {
        switch event {
        case "enqueued": return "trust_center_admission"
        case "step_blocked_on_approval", "approval_decision":
            return "canonical_approval_owner"
        case "completed": return "domain_outcome_verification"
        default: return nil
        }
    }

    private nonisolated static func procedureExternalEffectClass(
        event: String,
        tool: String?
    ) -> String {
        guard event == "step_completed" || event == "step_blocked_on_approval" else {
            return "local_control"
        }
        guard let tool = procedureToken(tool, maximum: 80) else { return "unknown" }
        switch tool {
        case "read_file", "list_dir", "search_chat_history", "recall_memory":
            return "local_read"
        case "write_file": return "local_write"
        case "chat.synthesize", "llm", "report": return "local_compute"
        default:
            let lowered = tool.lowercased()
            let sendMarkers = ["send", "post", "publish", "message", "upload", "email", "notify"]
            return sendMarkers.contains(where: lowered.contains) ? "external_send" : "unknown"
        }
    }

    private nonisolated static func procedureToken(_ raw: String?, maximum: Int) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= maximum else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// Hash input only. Keys and values never leave this function; values are
    /// reduced to bounded JSON types and object keys contribute only inside the
    /// opaque digest used to distinguish schema variations.
    private nonisolated static func procedureArgumentShape(
        _ value: JSONValue,
        depth: Int = 0
    ) -> String {
        guard depth < 4 else { return "depth" }
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .array(let values):
            let shapes = values.prefix(16).map {
                procedureArgumentShape($0, depth: depth + 1)
            }
            return "array[" + shapes.joined(separator: ",") + "]"
        case .object(let object):
            let fields = object.keys.sorted().prefix(32).map { key in
                let keyDigest = CausalTransitionEvidence.opaqueIdentity(String(key.prefix(128)))
                let shape = procedureArgumentShape(
                    object[key] ?? .null,
                    depth: depth + 1
                )
                return keyDigest + ":" + shape
            }
            return "object{" + fields.joined(separator: ",") + "}"
        }
    }
}

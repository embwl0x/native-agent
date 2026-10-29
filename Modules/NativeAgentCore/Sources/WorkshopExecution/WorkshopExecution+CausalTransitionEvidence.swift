import Foundation
import NativeAgentCore
import PersistenceCore
import Procedures

// Blueprint: | `WorkshopExecution+CausalTransitionEvidence.swift` | `SwiftNativeWorkshopRunner` causal/motor projections: payload-free canonical plan interpretation, provider accounting and evidence classes without fabricated execution |

extension SwiftNativeWorkshopRunner: MotorActionReadModelProviding {}

/// Pure payload-free interpretation of an already-canonical Workshop plan.
/// It classifies schema, shape, authority, and effect classes without
/// fabricating timeline events or implying that any step executed.
public struct WorkshopProcedureContractReadout: Sendable, Equatable {
    public let taskFamily: String
    public let inputClass: String
    public let parameterSchemaClass: String
    public let parameterSchemaIdentity: String
    public let procedureShapeIdentity: String
    public let authorityClass: String
    public let externalEffectClasses: [String]
}

public extension SwiftNativeWorkshopRunner {
    /// One rejection-free canonical trajectory must match the complete artifact.
    internal func matchingProcedureTrajectory(
        for artifact: DeclarativeProcedureArtifact, record: WorkshopExecutionRecord
    ) async throws -> ProcedureTrajectory? {
        let timeline = try await readTimeline(record.id)
        let extraction = ProcedureTrajectoryExtractor.extract(Self.causalTransitionEvidence(
            executionId: record.id, timeline: timeline, record: record
        ))
        guard extraction.rejections.isEmpty, extraction.trajectories.count == 1,
              let trajectory = extraction.trajectories.first else { return nil }
        let replay = ProcedureReplayEngine.replay(artifact, against: trajectory)
        guard replay.status == .matched,
              replay.matchedStepCount == artifact.transitionTable.count else { return nil }
        return trajectory
    }

    nonisolated static func procedureContractProjection(
        plan: [WorkshopExecutionStep], trustRequired: String, triggerSource: String
    ) -> WorkshopProcedureContractReadout {
        let schemaSource = plan.prefix(16).map {
            procedureArgumentShape($0.args)
        }.joined(separator: ">")
        // The explicit String result prevents SQL interpolation from hashing
        // a process-specific debug description into the procedure identity.
        let shapeSource = plan.prefix(16).map { step -> String in
            let tool = procedureToken(step.toolOrAction, maximum: 80) ?? "unknown"
            let autonomy = procedureToken(step.autonomy, maximum: 40) ?? "unknown"
            return "\(tool)|\(autonomy)"
        }.joined(separator: ">")
        let authorityClass: String = switch trustRequired {
        case "none", "draft_auto": "low_risk"
        case "send_approval": "confirm_required"
        default: "high_risk"
        }
        let inputClass: String = {
            // Person and agent submissions share the directed-input procedure family.
            if triggerSource == "manual" || triggerSource == "agent" { return "manual" }
            if triggerSource.hasPrefix("trigger:") { return "scheduled" }
            if triggerSource == "golden_eval" { return "evaluation" }
            return "background"
        }()
        let effects = Set(plan.prefix(16).map { step in
            procedureExternalEffectClass(event: "step_completed", tool: step.toolOrAction)
        }).union(["local_control"])
        return WorkshopProcedureContractReadout(
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
        guard let record = try await getWorkshopExecution(actionId) else { return nil }
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
        let contract = record.map {
            procedureContractProjection(plan: $0.plan, trustRequired: $0.trustRequired, triggerSource: $0.triggerSource)
        }

        for (index, value) in timeline.enumerated() {
            guard case .object(let row) = value,
                  case .string(let event)? = row["event"] else { continue }
            let occurredAt: String
            if case .string(let timestamp)? = row["ts"] { occurredAt = timestamp }
            else { occurredAt = "unknown" }
            let step: WorkshopExecutionStep? = {
                guard case .string(let stepID)? = row["step_id"] else { return nil }
                return planByStepID[stepID]
            }()
            var afterState = priorState
            var kind = event
            var expectedEvidence: String?
            var terminalClass: String?
            var verificationClass = "unknown"
            var actionKind: String?
            var evidenceKind = "domain_event"
            var checkpointClass: String?
            switch event {
            case "enqueued":
                afterState = "queued"
                expectedEvidence = "execution_start"
                actionKind = "queue_admission"
                evidenceKind = "queue_receipt"
                checkpointClass = "trust_center_admission"
            case "started":
                afterState = "running"
                expectedEvidence = "step_or_terminal_outcome"
                actionKind = "execute_plan"
                evidenceKind = "execution_claim"
            case "step_completed":
                afterState = "running"
                expectedEvidence = "step_or_terminal_outcome"
                verificationClass = "observed"
                actionKind = procedureToken(step?.toolOrAction, maximum: 80).map { "tool:\($0)" }
                evidenceKind = "step_receipt:unknown"
                if case .string(let rawStatus)? = row["status"],
                   let status = procedureToken(rawStatus, maximum: 40),
                   ["succeeded", "partial", "skipped", "failed", "cancelled", "blocked_on_approval", "stubbed"].contains(status) {
                    evidenceKind = "step_receipt:\(status)"
                }
            case "step_blocked_on_approval", "approval_decision":
                let blocked = event == "step_blocked_on_approval"
                afterState = blocked ? "blocked_on_approval" : "running"
                expectedEvidence = blocked ? "approval_resolution" : "step_or_terminal_outcome"
                verificationClass = "observed"
                actionKind = blocked ? "approval_stage" : "approval_resume"
                evidenceKind = blocked ? "approval_request" : "approval_decision"
                checkpointClass = "canonical_approval_owner"
            case "execution_interrupted":
                if case .string(let status)? = row["status"] { afterState = status }
                else { afterState = "blocked_on_reconciliation" }
                expectedEvidence = afterState == "queued" ? "execution_start" : "domain_reconciliation"
                actionKind = "release_claim"
                evidenceKind = "claim_release_receipt"
            case "completed":
                afterState = "completed"
                terminalClass = record?.verification?.status == .satisfied
                    ? "verified_success" : "unverified_success"
                switch record?.verification?.status {
                case .satisfied: verificationClass = "verified"
                case .failed: verificationClass = "failed"
                case .unverified, nil: verificationClass = "unverified"
                }
                evidenceKind = "domain_verification"
                checkpointClass = "domain_outcome_verification"
            case "failed":
                afterState = "failed"
                terminalClass = "verified_failure"
                verificationClass = "verified"
                evidenceKind = "terminal_failure"
            case "cancelled":
                afterState = "cancelled"
                terminalClass = "cancelled"
                verificationClass = "not_applicable"
                actionKind = "cancel"
                evidenceKind = "cancellation_receipt"
            case "planner_fallback", "approval_decision_ignored", "synthesize_untooled", "synthesize_validation_failed":
                break
            default:
                kind = "domain_specific"
            }
            let operationID = CausalTransitionEvidence.opaqueIdentity(
                "\(executionId)|\(index)|\(event)|\(occurredAt)"
            )
            let outcome: String
            if priorState == nil, afterState != nil { outcome = "item_created" }
            else if priorState != afterState { outcome = "state_changed" }
            else { outcome = "state_unchanged" }
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
                kind: kind,
                beforeState: priorState,
                afterState: afterState,
                expectedNextEvidence: expectedEvidence,
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
                actionKind: actionKind,
                evidenceKind: evidenceKind,
                checkpointClass: checkpointClass,
                retryClass: event == "execution_interrupted"
                    ? (afterState == "queued" ? "deterministic_resume" : "reconciliation_required") : nil,
                retryCount: terminalClass == nil ? nil : record?.rerunCount,
                cancellationClass: event == "cancelled" ? "canonical_user_cancellation" : nil,
                externalEffectClass: event == "execution_interrupted" && afterState != "queued"
                    ? "unknown" : procedureExternalEffectClass(
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

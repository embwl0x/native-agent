import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `WorkshopExecution+Types.swift` | Workshop execution value contracts: specs/steps, verification/records, enqueue outcomes, argument validation and planner interface |

// MARK: - Errors

public enum WorkshopExecutionError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case persistenceFailure(String)
    case plannerFailure(String)
    case underlying(String)
    // WAVE 41 W01 (REOPEN §6.220-rd2 #1): parity errors for the two daemon
    // submission gates the native writer must mirror.
    //
    // `.forbidden` — parity for the daemon route's 403 when missionPolicy is
    // off: the retired daemon returns
    //   {"error": "forbidden", "detail": "missionPolicy.enabled not set in trust policy"}
    // The associated value is that exact `detail` string so the seam can
    // reconstruct the same envelope.
    //
    // `.workshopExecutionsBusy` — parity for MissionsBusyError,
    // mapped by the daemon to HTTP 503 + MissionsBusyError.to_dict():
    //   {"ok": false, "error": "missions_busy", "retryable": true, "detail": ...}
    // The associated value is the same `detail` message string.
    case forbidden(String)
    case workshopExecutionsBusy(String)
    // STALE APPROVAL (2026-06-10, gpt-5.5 executor-port blocker #3): a
    // resume was requested for an execution that is no longer
    // blocked_on_approval (cancelled/failed/completed in the meantime).
    // The step was NOT executed. Distinct from `.invalidRequest` so the
    // approval-resolution caller can annotate the approval record honestly
    // ("execution no longer blocked — not executed") instead of reporting a
    // generic failure + claim-clear.
    case staleApproval(String)
    /// No slot was available; keep the resolved approval for a later drain.
    case approvalDeferred

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): return "invalid request: \(m)"
        case .persistenceFailure(let m): return "persistence failure: \(m)"
        case .plannerFailure(let m): return "planner failure: \(m)"
        case .underlying(let m): return m
        case .forbidden(let m): return m
        case .workshopExecutionsBusy(let m): return m
        case .staleApproval(let m): return m
        case .approvalDeferred: return "Approved Workshop step deferred until execution capacity is available"
        }
    }

    /// Parity error code for `.forbidden` / `.workshopExecutionsBusy` — the `error`
    /// field the daemon route puts in the JSON envelope. nil for the other
    /// cases (those map to 400/500/etc., not a single stable code).
    public var parityErrorCode: String? {
        switch self {
        case .forbidden: return "forbidden"
        case .workshopExecutionsBusy: return "missions_busy"
        default: return nil
        }
    }
}

// MARK: - Value types

/// Caller-facing execution spec. Matches MissionRunner.submit() arg surface
/// at the retired daemon: (title, objective, trigger_source,
/// trust_required).
public struct WorkshopExecutionSpec: Codable, Sendable, Equatable {
    public var title: String
    public var objective: String
    public var triggerSource: String     // "manual" (the person), "agent" (workshop_submit) or "trigger:<name>"
    public var trustRequired: String     // "none"|"draft_auto"|"send_approval"|"destructive_strong"
    /// Stable Desk identity for the Workshop-owned path. Nil is retained for
    /// daemon-era callers while consumers migrate shadow-first.
    public var deskHandle: String?
    /// Optional reference to the existing connector workspace registry. This
    /// is association metadata only; it grants no path or tool authority.
    public var projectSpaceId: String?
    public var expectedOutputs: [String]?

    public init(
        title: String,
        objective: String,
        triggerSource: String = "manual",
        trustRequired: String = "none",
        deskHandle: String? = nil,
        projectSpaceId: String? = nil,
        expectedOutputs: [String]? = nil
    ) {
        self.title = title
        self.objective = objective
        self.triggerSource = triggerSource
        self.trustRequired = trustRequired
        self.deskHandle = deskHandle
        self.projectSpaceId = projectSpaceId
        self.expectedOutputs = expectedOutputs
    }
}

/// Single plan step. Mirrors daemon @dataclass Step:
///   id, description, tool_or_action, args, autonomy.
public struct WorkshopExecutionStep: Codable, Sendable, Equatable {
    public var id: String
    public var description: String
    public var toolOrAction: String
    public var args: JSONValue           // .object(...) keeps Python's flat dict shape
    public var autonomy: String          // "auto" | "needs_approval"
    public var argumentSchema: JSONValue? = nil

    public init(
        id: String,
        description: String,
        toolOrAction: String,
        args: JSONValue = .object([:]),
        autonomy: String = "auto",
        argumentSchema: JSONValue? = nil
    ) {
        self.id = id
        self.description = description
        self.toolOrAction = toolOrAction
        self.args = args
        self.autonomy = autonomy
        self.argumentSchema = argumentSchema
    }

    /// Emit the asdict(step) shape (snake_case keys, raw JSON values).
    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "description": .string(description),
            "tool_or_action": .string(toolOrAction),
            "args": args,
            "autonomy": .string(autonomy),
        ]
        if let argumentSchema { object["argument_schema"] = argumentSchema }
        return .object(object)
    }
}

/// Durable, domain-owned verification of a Workshop execution's declared
/// result. This is deliberately small: it records whether the executor could
/// prove the outcome from exact local evidence, not the payload that was read.
/// Unsupported external effects remain `unverified`; they are never promoted
/// to success merely because a tool returned without throwing.
public enum WorkshopVerificationStatus: String, Codable, Sendable, Equatable {
    case satisfied
    case failed
    case unverified
}

public struct WorkshopVerificationRecord: Codable, Sendable, Equatable {
    public var status: WorkshopVerificationStatus
    public var checkedAt: String
    public var methods: [String]
    public var detail: String

    public init(
        status: WorkshopVerificationStatus,
        checkedAt: String,
        methods: [String] = [],
        detail: String = ""
    ) {
        self.status = status
        self.checkedAt = checkedAt
        self.methods = Array(methods.prefix(16)).map { String($0.prefix(80)) }
        self.detail = String(detail.prefix(240))
    }

    public func toJSON() -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "checked_at": .string(checkedAt),
            "methods": .array(methods.map(JSONValue.string)),
            "detail": .string(detail),
        ])
    }

    public static func fromJSON(_ value: JSONValue?) -> Self? {
        guard case .object(let object)? = value,
              case .string(let rawStatus)? = object["status"],
              let status = WorkshopVerificationStatus(rawValue: rawStatus)
        else { return nil }
        let checkedAt: String = {
            if case .string(let value)? = object["checked_at"] { return value }
            return ""
        }()
        let methods: [String] = {
            guard case .array(let values)? = object["methods"] else { return [] }
            return values.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            }
        }()
        let detail: String = {
            if case .string(let value)? = object["detail"] { return value }
            return ""
        }()
        return Self(status: status, checkedAt: checkedAt, methods: methods, detail: detail)
    }
}

/// Persisted execution record. Field order + names match the Python @dataclass
/// Execution so asdict() output is shape-identical.
public struct WorkshopExecutionRecord: Codable, Sendable, Equatable {
    /// Every planned step must have explicit integer-zero provider accounting.
    var hasExactZeroProviderStepAccounting: Bool {
        guard stepsCompleted.count == plan.count else { return false }
        return stepsCompleted.allSatisfy { row in
            guard case .object(let object) = row,
                  case .int(0)? = object["provider_call_count"],
                  case .int(0)? = object["removable_orchestration_provider_call_count"] else {
                return false
            }
            return true
        }
    }

    public var id: String
    public var lifeID: String? = nil
    /// Authoritative Workshop/Desk identity. The execution id remains an
    /// internal compatibility key until the legacy queue is retired.
    public var deskHandle: String? = nil
    public var projectSpaceId: String? = nil
    public var title: String
    public var objective: String
    public var createdAt: String         // "created_at" in JSON
    public var status: String            // "queued"|"running"|"blocked_on_approval"|"blocked_on_reconciliation"|"completed"|"failed"|"cancelled"|"stopped"
    public var plan: [WorkshopExecutionStep]
    public var stepsCompleted: [JSONValue]   // "steps_completed" — opaque from Swift's POV
    public var receiptsDir: String       // "receipts_dir" — absolute path to receipts/
    public var triggerSource: String     // "trigger_source"
    public var trustRequired: String     // "trust_required"
    public var expectedOutputs: [JSONValue]  // "expected_outputs"
    public var currentStepId: String     // "current_step_id"
    public var updatedAt: String         // "updated_at"
    public var result: JSONValue         // null|string|object — match Python's "result: str | None"
    public var rerunCount: Int           // "rerun_count"
    /// Direct provider call made by Workshop planning. Additive and optional:
    /// legacy records stay unknown rather than being backfilled.
    public var planningProviderCallCount: Int? = nil
    /// Subset of planning calls proven removable by a compiled declarative
    /// procedure. This is currently the planner call, never synthesis calls.
    public var planningRemovableOrchestrationProviderCallCount: Int? = nil
    /// Optional post-cutover extension. Absence means an older/unverified
    /// record; it never defaults to satisfied.
    public var verification: WorkshopVerificationRecord? = nil
    /// Executor-owned movement; metadata edits only change updatedAt.
    public var lastMovementAt: String? = nil
    public var compiledOperationBinding: JSONValue? = nil
    public var terminalReason: String? = nil

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "objective": .string(objective),
            "created_at": .string(createdAt),
            "status": .string(status),
            "plan": .array(plan.map { $0.toJSON() }),
            "steps_completed": .array(stepsCompleted),
            "receipts_dir": .string(receiptsDir),
            "trigger_source": .string(triggerSource),
            "trust_required": .string(trustRequired),
            "expected_outputs": .array(expectedOutputs),
            "current_step_id": .string(currentStepId),
            "updated_at": .string(updatedAt),
            "result": result,
            "rerun_count": .int(Int64(rerunCount)),
        ]
        if let deskHandle, !deskHandle.isEmpty {
            object["desk_handle"] = .string(deskHandle)
        }
        if let projectSpaceId, !projectSpaceId.isEmpty {
            object["project_space_id"] = .string(projectSpaceId)
        }
        if let verification {
            object["verification"] = verification.toJSON()
        }
        if let lastMovementAt {
            object["last_movement_at"] = .string(lastMovementAt)
        }
        if let compiledOperationBinding { object["compiled_operation_binding"] = compiledOperationBinding }
        if let lifeID { object["lifeID"] = .string(lifeID) }
        if let terminalReason { object["terminal_reason"] = .string(terminalReason) }
        if let planningProviderCallCount {
            object["planning_provider_call_count"] = .int(Int64(planningProviderCallCount))
        }
        if let planningRemovableOrchestrationProviderCallCount {
            object["planning_removable_orchestration_provider_call_count"] = .int(
                Int64(planningRemovableOrchestrationProviderCallCount)
            )
        }
        return .object(object)
    }
}

/// Envelope returned by submit(). Matches daemon's `MissionRunner.submit()`
/// return shape (a Execution record), but pulled to the fields the trigger
/// scheduler fire_now path needs ({status, mission_id}).
public struct WorkshopExecutionEnqueueResult: Codable, Sendable, Equatable {
    public var status: String            // "queued" — terminal status of submit (NOT "fired")
    public var executionId: String
    public var record: WorkshopExecutionRecord     // full record for callers that want it

    enum CodingKeys: String, CodingKey {
        case status, record
        case executionId = "missionId" // compatibility wire ID
    }

    public init(status: String, executionId: String, record: WorkshopExecutionRecord) {
        self.status = status
        self.executionId = executionId
        self.record = record
    }
}

// MARK: - Planner LLM hook

public enum WorkshopArgumentValidation {
    public static func validate(_ value: JSONValue, schema: JSONValue) throws {
        guard let problem = value.schemaProblem(schema: schema) else { return }
        let message: String
        switch problem.keyword {
        case "schema": message = "tool argument schema is unavailable: \(problem.expected)"
        case "type": message = "tool argument has an incompatible schema type"
        case "enum": message = "tool argument is outside its declared values"
        case "required": message = "missing tool argument: \(problem.path)"
        case "additionalProperties": message = "unknown tool argument: \(problem.path)"
        default: message = "tool argument \(problem.path) must be \(problem.expected)"
        }
        throw WorkshopExecutionError.invalidRequest(message)
    }
}

/// Planner provider seam; production uses `SwiftNativeWorkshopPlannerLLM`.
public protocol WorkshopPlannerLLM: Sendable {
    /// Exact direct provider calls issued by one `runCodex` invocation. A
    /// custom/test adapter that cannot prove this leaves it nil; callers must
    /// not infer provider usage merely because the method was invoked.
    var directProviderCallCountPerInvocation: Int? { get }
    /// Available connector action descriptors; an empty list is supported.
    func availableConnectorActions() async -> [JSONValue]

    /// Run the planner on the routed surface and return (model, raw output).
    /// Planning errors propagate to the caller.
    func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String)
}

public extension WorkshopPlannerLLM {
    var directProviderCallCountPerInvocation: Int? { nil }
}

/// Deny-LLM implementation: no connector actions; planning throws.
public struct StubWorkshopPlannerLLM: WorkshopPlannerLLM {
    public init() {}
    public var directProviderCallCountPerInvocation: Int? { 0 }
    public func availableConnectorActions() async -> [JSONValue] { [] }
    public func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String) {
        throw WorkshopExecutionError.plannerFailure("stub planner does not run codex")
    }
}

import Foundation
import NativeAgentShared
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `WorkshopExecution+Types.swift` | Workshop execution value contracts: specs/steps with optional-read intent, verification/records, enqueue outcomes, argument validation and planner interface |

// MARK: - Errors

public enum WorkshopExecutionError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case persistenceFailure(String)
    case plannerFailure(String)
    case underlying(String)
    // Admission errors retain their detail string and stable wire error code.
    case forbidden(String)
    case workshopExecutionsBusy(String)
    // A stale approval did not execute: the execution is no longer blocked, so resolution must record that outcome distinctly.
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

    /// Stable JSON-envelope error code for admission refusals; nil for other errors.
    public var parityErrorCode: String? {
        switch self {
        case .forbidden: return "forbidden"
        case .workshopExecutionsBusy: return "missions_busy"
        default: return nil
        }
    }
}

// MARK: - Value types

/// Caller-facing execution spec.
public struct WorkshopExecutionSpec: Codable, Sendable, Equatable {
    public var title: String
    public var objective: String
    public var triggerSource: String     // "manual" (the person), "agent" (workshop_submit) or "trigger:<name>"
    public var trustRequired: String     // "none"|"draft_auto"|"send_approval"|"destructive_strong"
    /// Stable Desk identity when the caller associates the execution with Desk work.
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

/// One planned call. Optional reads may supply no evidence; effects remain required.
public struct WorkshopExecutionStep: Codable, Sendable, Equatable {
    public var id: String
    public var description: String
    public var toolOrAction: String
    public var args: JSONValue           // .object(...) keeps Python's flat dict shape
    public var autonomy: String          // "auto" | "needs_approval"
    public var argumentSchema: JSONValue? = nil
    /// Nil on older plans means required. Read/effect class comes from the call's declaration.
    public var optional: Bool? = nil

    public init(
        id: String,
        description: String,
        toolOrAction: String,
        args: JSONValue = .object([:]),
        autonomy: String = "auto",
        argumentSchema: JSONValue? = nil,
        optional: Bool? = nil
    ) {
        self.id = id
        self.description = description
        self.toolOrAction = toolOrAction
        self.args = args
        self.autonomy = autonomy
        self.argumentSchema = argumentSchema
        self.optional = optional
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
        if let optional { object["optional"] = .bool(optional) }
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
        let checkedAt = object["checked_at"]?.stringValue ?? ""
        let methods = object["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let detail = object["detail"]?.stringValue ?? ""
        return Self(status: status, checkedAt: checkedAt, methods: methods, detail: detail)
    }
}

/// Persisted execution record. Field order + names match the Python @dataclass
/// Execution so asdict() output is shape-identical.
public struct WorkshopExecutionRecord: Codable, Sendable, Equatable {
    public static func isSuccessful(_ status: String) -> Bool { ["completed", "done", "succeeded"].contains(status.lowercased()) }
    public static func isTerminal(_ status: String) -> Bool { isSuccessful(status) || ["failed", "cancelled", "canceled", "stopped", "unverified"].contains(status.lowercased()) }
    public var isTerminal: Bool { Self.isTerminal(status) }
    public var isSuccessful: Bool { Self.isSuccessful(status) }
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

/// Submission status, execution identity and full record; executionId remains encoded as missionId.
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

/// Typed planner seam; provider planning owns its prompt and decoding.
public protocol WorkshopPlannerLLM: Sendable {
    func plan(spec: WorkshopExecutionSpec, dataRoot: URL, now: Date) async throws
        -> (steps: [WorkshopExecutionStep], providerCallCount: Int?, binding: WorkshopCompiledFileCopyBinding?)
}

/// Planning without a configured planner refuses work.
public struct StubWorkshopPlannerLLM: WorkshopPlannerLLM {
    public init() {}
    public func plan(spec: WorkshopExecutionSpec, dataRoot: URL, now: Date) async throws
        -> (steps: [WorkshopExecutionStep], providerCallCount: Int?, binding: WorkshopCompiledFileCopyBinding?) {
        throw WorkshopExecutionError.plannerFailure("stub planner cannot produce a plan")
    }
}

import NativeAgentCore
import PersistenceCore
// Blueprint: | `WorkshopExecutorContracts.swift` | Workshop step approval/dispatch contracts and outcomes with independent read coverage |

// MARK: - Injected closure types

/// One staged Workshop execution-step approval. The app layer turns this into an
/// ApprovalInbox record + a notifications/inbox.jsonl card whose id equals
/// the approval id (mirror of the REM stager contract).
public struct WorkshopStepApprovalRequest: Sendable, Equatable {
    public var executionId: String
    public var stepId: String
    public var taskTitle: String
    public var actionDescription: String
    public var title: String
    public var tool: String
    public var reason: String
    public var args: JSONValue
    public var sourceArgs: JSONValue

    public init(executionId: String, stepId: String, taskTitle: String, actionDescription: String, title: String, tool: String, reason: String, args: JSONValue, sourceArgs: JSONValue) {
        self.executionId = executionId
        self.stepId = stepId
        self.taskTitle = taskTitle
        self.actionDescription = actionDescription
        self.title = title
        self.tool = tool
        self.reason = reason
        self.args = args
        self.sourceArgs = sourceArgs
    }
}

/// Stage an approval; return the approval id, or nil when staging failed
/// (the step then FAILS honestly — a Workshop execution must never block on an approval
/// that was never filed).
public typealias WorkshopStepApprovalStager = @Sendable (WorkshopStepApprovalRequest) async -> String?

/// Exact accounting returned by production Workshop-owned model seams. The
/// removable count is narrower than the provider count: synthesis still
/// needs cognition after a procedure is compiled, while orchestration/planning
/// may disappear.
public struct WorkshopStepLLMCompletion: Sendable, Equatable {
    public let model: String
    public let text: String
    public let providerCallCount: Int
    public let removableOrchestrationProviderCallCount: Int

    public init(
        model: String,
        text: String,
        providerCallCount: Int,
        removableOrchestrationProviderCallCount: Int = 0
    ) {
        self.model = model
        self.text = text
        self.providerCallCount = providerCallCount
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
    }
}

public typealias WorkshopStepMeasuredLLM = @Sendable (_ prompt: String) async throws -> WorkshopStepLLMCompletion

/// Tool dispatch for non-LLM steps. `args` is the step's flat JSON object.
/// A read failure supplies no evidence: required reads fail, optional reads
/// record unavailability and continue. Effect failures fail the step; unknown
/// tools MUST throw, never return a fabricated success.
public typealias WorkshopStepToolDispatch = @Sendable (_ tool: String, _ args: JSONValue) async throws -> JSONValue
public typealias WorkshopStepApprovedToolDispatch = @Sendable (_ tool: String, _ args: JSONValue, _ approvalId: String) async throws -> JSONValue

/// Emitted only after a terminal Workshop execution CAS wins. App assembly can observe
/// completed/failed/cancelled outcomes without WorkshopExecution importing
/// app-side cognition or notification surfaces.
public typealias WorkshopTerminalEventSink = @Sendable (_ record: WorkshopExecutionRecord, _ reason: String?) async -> Void

// MARK: - Step outcome

public enum WorkshopReadCoverage: String, Sendable, Equatable {
    case complete, partial, absent, unavailable
}

/// Step outcome serialized into execution.json steps_completed with stable snake_case keys.
public struct WorkshopStepOutcome: Sendable, Equatable {
    public static let successStatus = "succeeded"
    public var stepId: String
    public var status: String        // "succeeded"|"partial"|"skipped"|"failed"|"blocked_on_approval"|"rejected"|"cancelled"
    public var output: JSONValue     // defaults to .object([:])
    public var error: String
    public var approvalId: String
    public var executedAt: String
    /// Read evidence, independent of the plan's ability to continue. The raw reply stays in output.
    public var readCoverage: WorkshopReadCoverage?
    /// Direct provider calls owned by this Workshop step. Nil means the
    /// injected/legacy seam did not prove an exact count.
    public var providerCallCount: Int?
    /// Subset of providerCallCount proven removable by declarative procedure
    /// compilation. Nil follows unknown provider accounting.
    public var removableOrchestrationProviderCallCount: Int?

    public init(
        stepId: String,
        status: String,
        output: JSONValue = .object([:]),
        error: String = "",
        approvalId: String = "",
        executedAt: String,
        providerCallCount: Int? = nil,
        removableOrchestrationProviderCallCount: Int? = nil,
        readCoverage: WorkshopReadCoverage? = nil
    ) {
        self.stepId = stepId
        self.status = status
        self.output = output
        self.error = error
        self.approvalId = approvalId
        self.executedAt = executedAt
        self.providerCallCount = providerCallCount
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
        self.readCoverage = readCoverage
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "step_id": .string(stepId),
            "status": .string(status),
            "output": output,
            "error": .string(error),
            "approval_id": .string(approvalId),
            "executed_at": .string(executedAt),
        ]
        if let providerCallCount {
            object["provider_call_count"] = .int(Int64(providerCallCount))
        }
        if let removableOrchestrationProviderCallCount {
            object["removable_orchestration_provider_call_count"] =
                .int(Int64(removableOrchestrationProviderCallCount))
        }
        if let readCoverage { object["read_coverage"] = .string(readCoverage.rawValue) }
        return .object(object)
    }
}

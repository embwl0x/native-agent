import NativeAgentCore
import PersistenceCore

// MARK: - Injected closure types

/// One staged Workshop execution-step approval. The app layer turns this into an
/// ApprovalInbox record + a notifications/inbox.jsonl card whose id equals
/// the approval id (mirror of the REM stager contract).
public struct WorkshopStepApprovalRequest: Sendable, Equatable {
    public var executionId: String
    public var stepId: String
    public var title: String
    public var tool: String
    public var reason: String
    public var args: JSONValue

    public init(executionId: String, stepId: String, title: String, tool: String, reason: String, args: JSONValue) {
        self.executionId = executionId
        self.stepId = stepId
        self.title = title
        self.tool = tool
        self.reason = reason
        self.args = args
    }
}

/// Stage an approval; return the approval id, or nil when staging failed
/// (the step then FAILS honestly — a Workshop execution must never block on an approval
/// that was never filed).
public typealias WorkshopStepApprovalStager = @Sendable (WorkshopStepApprovalRequest) async -> String?

/// LLM completion for "llm"/"report"/chat.synthesize steps. Returns
/// (model, text) — the daemon's run_codex(prompt, timeout=120) pair.
///
/// NOTE (synthesize-quality fix, 2026-06-11): a BARE completion via this
/// closure has NO tool access — the model cannot read the files / memory the
/// synthesize step is supposed to summarize, so it tends to refuse ("I can't
/// access your filesystem"). Prefer the tool-capable closure below; this
/// stays as the honest fallback (with a `synthesize_untooled` timeline note).
public typealias WorkshopStepLLM = @Sendable (_ prompt: String) async throws -> (model: String, text: String)

/// TOOL-CAPABLE synthesize turn (synthesize-quality fix, 2026-06-11). Same
/// (model, text) return as the bare closure, but the prompt is run through a
/// tool loop wired (in BackgroundLoopsAssembly) to a RESTRICTED, READ-ONLY
/// tool set — read_file / list_dir / search_chat_history / recall_memory and
/// their read aliases ONLY; no shell, no write tools, no workshop_submit
/// (recursion). The autonomy gate still governs the dispatched tools. When
/// this is wired the executor routes synthesize steps here instead of the
/// bare `llmStep`, so the model can actually fetch what it's asked to
/// synthesize rather than refusing for lack of access.
public typealias WorkshopStepTooledLLM = @Sendable (_ prompt: String) async throws -> (model: String, text: String)

/// Exact accounting returned by production Workshop-owned model seams. The
/// removable count is narrower than the provider count: synthesis still
/// needs cognition after a procedure is compiled, while orchestration/planning
/// may disappear. Legacy tuple closures remain supported but cannot fabricate
/// these facts.
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
/// Throw to fail the step; unknown tools MUST throw (honest failure), never
/// return a fabricated success.
public typealias WorkshopStepToolDispatch = @Sendable (_ tool: String, _ args: JSONValue) async throws -> JSONValue

/// Emitted only after a terminal Workshop execution CAS wins. App assembly can observe
/// completed/failed/cancelled outcomes without WorkshopExecution importing
/// app-side cognition or notification surfaces.
public typealias WorkshopTerminalEventSink = @Sendable (_ record: WorkshopExecutionRecord, _ reason: String?) async -> Void

// MARK: - Step outcome

/// Mirror of the daemon @dataclass StepResult.
/// Serialized into mission.json `steps_completed` with the same snake_case
/// keys as Python's asdict(StepResult).
public struct WorkshopStepOutcome: Sendable, Equatable {
    public var stepId: String
    public var status: String        // "succeeded"|"failed"|"blocked_on_approval"|"rejected"|"cancelled"
    public var output: JSONValue     // .object — daemon default {}
    public var error: String
    public var approvalId: String
    public var executedAt: String
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
        removableOrchestrationProviderCallCount: Int? = nil
    ) {
        self.stepId = stepId
        self.status = status
        self.output = output
        self.error = error
        self.approvalId = approvalId
        self.executedAt = executedAt
        self.providerCallCount = providerCallCount
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
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
        return .object(object)
    }
}

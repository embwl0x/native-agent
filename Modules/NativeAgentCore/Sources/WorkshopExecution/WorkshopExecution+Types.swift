import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - Errors

public enum WorkshopExecutionError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case persistenceFailure(String)
    case unavailable
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
    // EXECUTOR GATE (2026-06-10): submit refuses while no Swift executor
    // exists (queued executions could never run). Distinct from `.unavailable`
    // (start()'s generic shape) so consumers can render the actionable
    // message instead of a bare "executions unavailable".
    case executorUnavailable(String)
    // STALE APPROVAL (2026-06-10, gpt-5.5 executor-port blocker #3): a
    // resume was requested for an execution that is no longer
    // blocked_on_approval (cancelled/failed/completed in the meantime).
    // The step was NOT executed. Distinct from `.invalidRequest` so the
    // approval-resolution caller can annotate the approval record honestly
    // ("execution no longer blocked — not executed") instead of reporting a
    // generic failure + claim-clear.
    case staleApproval(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): return "invalid request: \(m)"
        case .persistenceFailure(let m): return "persistence failure: \(m)"
        case .unavailable: return "Workshop execution unavailable"
        case .plannerFailure(let m): return "planner failure: \(m)"
        case .underlying(let m): return m
        case .forbidden(let m): return m
        case .workshopExecutionsBusy(let m): return m
        case .executorUnavailable(let m): return m
        case .staleApproval(let m): return m
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
    public var triggerSource: String     // "manual" or "trigger:<name>"
    public var trustRequired: String     // "none"|"draft_auto"|"send_approval"|"destructive_strong"
    /// Stable Desk identity for the Workshop-owned path. Nil is retained for
    /// daemon-era callers while consumers migrate shadow-first.
    public var deskHandle: String?

    public init(
        title: String,
        objective: String,
        triggerSource: String = "manual",
        trustRequired: String = "none",
        deskHandle: String? = nil
    ) {
        self.title = title
        self.objective = objective
        self.triggerSource = triggerSource
        self.trustRequired = trustRequired
        self.deskHandle = deskHandle
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

    public init(
        id: String,
        description: String,
        toolOrAction: String,
        args: JSONValue = .object([:]),
        autonomy: String = "auto"
    ) {
        self.id = id
        self.description = description
        self.toolOrAction = toolOrAction
        self.args = args
        self.autonomy = autonomy
    }

    /// Emit the asdict(step) shape (snake_case keys, raw JSON values).
    public func toJSON() -> JSONValue {
        return .object([
            "id": .string(id),
            "description": .string(description),
            "tool_or_action": .string(toolOrAction),
            "args": args,
            "autonomy": .string(autonomy),
        ])
    }
}

/// Result of planWorkshopExecution(). plan is ≥1 step (stub fallback guarantees this);
/// `fromStub` distinguishes "real LLM plan" from "deterministic fallback"
/// for tests + observability.
public struct WorkshopExecutionPlan: Codable, Sendable, Equatable {
    public var steps: [WorkshopExecutionStep]
    public var fromStub: Bool

    public init(steps: [WorkshopExecutionStep], fromStub: Bool) {
        self.steps = steps
        self.fromStub = fromStub
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
    public var id: String
    /// Authoritative Workshop/Desk identity. The execution id remains an
    /// internal compatibility key until the legacy queue is retired.
    public var deskHandle: String? = nil
    public var title: String
    public var objective: String
    public var createdAt: String         // "created_at" in JSON
    public var status: String            // "queued"|"running"|"blocked_on_approval"|"completed"|"failed"|"cancelled"
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
        if let verification {
            object["verification"] = verification.toJSON()
        }
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

/// Envelope returned by start().
public struct WorkshopExecutionStartResult: Codable, Sendable, Equatable {
    public var executionId: String
    public var status: String            // post-start status

    enum CodingKeys: String, CodingKey {
        case status
        case executionId = "missionId" // compatibility wire ID
    }

    public init(executionId: String, status: String) {
        self.executionId = executionId
        self.status = status
    }
}

// MARK: - Planner LLM hook

/// Pluggable LLM call for the planner. The default HTTP-backed impl asks
/// the daemon to run codex; tests pass a deterministic stub. The protocol
/// also exposes the connector-action list so the planner can build
/// tools_summary; the daemon answers that one too.
public protocol WorkshopPlannerLLM: Sendable {
    /// Exact direct provider calls issued by one `runCodex` invocation. A
    /// custom/test adapter that cannot prove this leaves it nil; callers must
    /// not infer provider usage merely because the method was invoked.
    var directProviderCallCountPerInvocation: Int? { get }
    /// Live connector_actions list. Each element is the daemon's
    /// connector_actions_registry().actions[i] dict (id/description/...).
    /// Returning [] is allowed and matches Python's silent-except fallback.
    func availableConnectorActions() async -> [JSONValue]

    /// Run codex with the assembled prompt; return (model, raw output).
    /// `surface` is "workshop" (P2-3; "missions" before 0.3.8 and still
    /// accepted) so the per-surface provider routing
    /// applies. Any error → caller treats it as a planner failure and falls
    /// back to the stub.
    func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String)
}

public extension WorkshopPlannerLLM {
    var directProviderCallCountPerInvocation: Int? { nil }
}

/// Default deny-LLM impl — returns no connector actions and refuses to run
/// codex. Wired by the SwiftNative factory when no real planner is
/// available, so the runner ALWAYS falls back to the deterministic stub.
/// Used by tests and by callers that don't want the daemon round-trip.
public struct StubWorkshopPlannerLLM: WorkshopPlannerLLM {
    public init() {}
    public var directProviderCallCountPerInvocation: Int? { 0 }
    public func availableConnectorActions() async -> [JSONValue] { [] }
    public func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String) {
        throw WorkshopExecutionError.plannerFailure("stub planner does not run codex")
    }
}

// MARK: - Tool autonomy (planner-side use only)

/// Subset of the retired daemon::DEFAULT_TOOL_AUTONOMY needed for the
/// planner's `tools_summary` rendering. The dispatch-time autonomy gate
/// stays in the Python executor; we only use this map for the planner
/// prompt's `[autonomy=...]` annotation. Keep in sync with missions.py
/// L150-L213 — any divergence is a planner-prompt drift, not a security
/// gap (the gate lives elsewhere).
enum DefaultToolAutonomy {
    static let map: [String: String] = [
        "search.*": "auto",
        "chat.synthesize": "auto",
        "local_files.search": "auto",
        "local_files.read": "auto",
        "local_files.list": "auto",
        "searxng.search": "auto",
        "searxng.fetch": "auto",
        "github.search_issues": "auto",
        "github.list_repos": "auto",
        "github.list_issues": "auto",
        "github.set_repo_visibility": "confirm",
        "github_set_repo_visibility": "confirm",
        "gh.search_issues": "auto",
        "gh.list_repos": "auto",
        "gh.get_issue": "auto",
        "gh.get_pull_request": "auto",
        "gh.create_issue": "draft_auto",
        "gmail.list_inbox": "auto",
        "gmail.read": "auto",
        "gmail.search": "auto",
        "gmail.draft": "auto",
        "gmail.send": "send_approval",
        "agentmail.list_inbox": "auto",
        "agentmail.read": "auto",
        "agentmail.search": "auto",
        "agentmail.send": "send_approval",
        "email.list_inbox": "auto",
        "email.draft": "auto",
        "email.send": "send_approval",
        "calendar.list_events": "auto",
        "calendar.availability": "auto",
        "calendar.find_availability": "auto",
        "calendar.create_event": "draft_auto",
        "calendar.cancel_event": "send_approval",
        "notion.search": "auto",
        "notion.read_page": "auto",
        "notion.query_database": "auto",
        "notion.create_page": "draft_auto",
        "notion.append_block": "draft_auto",
        "slack.status": "auto",
        "slack.list_channels": "auto",
        "slack.search_messages": "auto",
        "slack.list_unreads": "auto",
        "slack.post_message": "send_approval",
        "browser.navigate": "auto",
        "browser.screenshot": "auto",
        "browser.read_text": "auto",
        "default": "send_approval",
    ]

    static let approvalRank: [String: Int] = [
        "auto": 0,
        "draft_auto": 1,
        "send_approval": 2,
        "destructive_strong": 3,
    ]

    /// Mirrors the retired daemon::resolve_tool_autonomy.
    /// 1. exact match
    /// 2. glob match, longest-pattern-first
    /// 3. "default" key.
    static func resolve(toolId: String) -> String {
        if let v = map[toolId] { return v }
        let patterns = map.keys
            .filter { $0 != "default" }
            .sorted { $0.count > $1.count }
        for pat in patterns {
            if Self.fnmatch(pat, toolId) {
                return map[pat]!
            }
        }
        return map["default"] ?? "send_approval"
    }

    static func needsApproval(_ level: String) -> Bool {
        (approvalRank[level] ?? 99) >= (approvalRank["send_approval"] ?? 2)
    }

    /// True iff `toolId` matches an EXPLICIT autonomy entry (exact or glob) —
    /// i.e. NOT governed by the catch-all "default" key. The non-yolo step gate
    /// uses this to enforce a KNOWN tool's intrinsic autonomy (so the planner
    /// can't mark email.send as "auto" to skip approval) WITHOUT force-gating
    /// unknown tools — those must still reach dispatch and fail honestly when no
    /// dispatcher is wired (unknownStepKindFailsHonestlyWithoutDispatcher).
    static func hasKnownEntry(_ toolId: String) -> Bool {
        if map[toolId] != nil { return true }
        for pat in map.keys where pat != "default" {
            if fnmatch(pat, toolId) { return true }
        }
        return false
    }

    /// Minimal fnmatch supporting `*` only (matches Python's fnmatch on the
    /// patterns we actually use, which are all `prefix.*` style). No `?`,
    /// no character classes — none of the DEFAULT_TOOL_AUTONOMY keys use
    /// them. Anchored on both ends.
    static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        if !pattern.contains("*") { return pattern == name }
        // Split on `*` and match each chunk left-to-right.
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        // Anchoring: first chunk must be prefix, last chunk must be suffix.
        var rest = name[...]
        for (idx, chunk) in parts.enumerated() {
            if chunk.isEmpty { continue }
            if idx == 0 {
                guard rest.hasPrefix(chunk) else { return false }
                rest = rest.dropFirst(chunk.count)
            } else if idx == parts.count - 1 {
                guard rest.hasSuffix(chunk) else { return false }
                rest = rest.dropLast(chunk.count)
            } else {
                guard let r = rest.range(of: chunk) else { return false }
                rest = rest[r.upperBound...]
            }
        }
        return true
    }
}

// MARK: - Protocol

public protocol WorkshopRunnerClient: Sendable {
    /// Build a plan for `spec`. Always returns ≥1 step (stub fallback).
    func planWorkshopExecution(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionPlan

    /// Plan + enqueue. Writes timeline.jsonl ("enqueued") first, then
    /// mission.json. Returns the persisted record.
    func submit(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionEnqueueResult

    /// Kick the executor for an already-enqueued execution. SwiftNative fails
    /// closed until the executor loop is ported.
    func start(executionId: String) async throws -> WorkshopExecutionStartResult

    /// Cancel a queued/running execution — the execution-lifecycle WRITE for
    /// POST /v1/missions/<id>/cancel. Mirrors MissionRunner.cancel
    ///: idempotent (already-cancelled → no-op,
    /// returns the unchanged record), sets status="cancelled", persists
    /// mission.json, appends a `cancelled` timeline event. Returns the
    /// post-cancel record. Throws .invalidRequest("Workshop execution not found: <id>")
    /// when the execution directory has no parseable mission.json — matching
    /// Python's `ValueError(f"Workshop execution not found: {mission_id}")`.
    ///
    /// NOTE (retirement_path / KEEP reason): the Python handler ALSO runs two
    /// daemon-internal side-effects the SwiftNative module cannot yet perform —
    /// `_purge_mission_scratchpad` (Scratchpad lives in the Dispatcher/runtime,
    /// not this module) and `_notify_mission(... "cancelled")` (the harness
    /// incident detector + mobile push). Those are best-effort, non-lifecycle
    /// side-effects. The DURABLE state transition (status + mission.json +
    /// timeline) is fully native here; the route stays live until the
    /// scratchpad-purge and harness-notify subsystems are ported.
    func cancel(executionId: String) async throws -> WorkshopExecutionRecord

    /// In-place field mutation for the queue-bridge half of POST
    /// /v1/missions/update. Mirrors the `_missions_allowed()` queue-bridge
    /// branch of Runtime.update_mission:
    /// applies title/objective/status/result patches to the queue execution's
    /// mission.json under flock, clears current_step_id on a terminal status,
    /// bumps updated_at, and returns the post-patch record. Returns nil when
    /// the id is NOT a queue execution; callers should surface that historical
    /// missions.jsonl rows are not handled by the queue bridge.
    func updateWorkshopExecution(_ patch: WorkshopExecutionUpdate) async throws -> WorkshopExecutionRecord?
}

/// Field patch for the queue-bridge half of POST /v1/missions/update.
/// `nil` means "field absent in the request body" → leave unchanged, exactly
/// like Python's `if "title" in body:` presence checks (L5385-L5398). An
/// EMPTY string for title/objective is treated by Python as "fall back to the
/// existing value" (`str(body.get("title") or qm.title)`), so we model that
/// distinction faithfully: a present-but-empty title/objective keeps the old
/// value, while `status`/`result` overwrite verbatim (Python lets them go
/// empty). `summary` is the alias Python accepts for `result`.
public struct WorkshopExecutionUpdate: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var objective: String?
    public var status: String?
    public var result: String?

    public init(id: String, title: String? = nil, objective: String? = nil, status: String? = nil, result: String? = nil) {
        self.id = id
        self.title = title
        self.objective = objective
        self.status = status
        self.result = result
    }

    /// Decode from the daemon's request-body dict. Mirrors the key set Python
    /// reads at L5370 (`id`/`mission_id`) and L5385-L5398
    /// (`title`/`objective`/`status`/`summary`/`result`). Presence — not just
    /// non-nil-ness — is what Python branches on, so we only populate a field
    /// when its key is actually present in `body`.
    /// Retired truthiness for a JSON value (matches `bool(x)` for the scalar
    /// types `body.get(...)` can return): absent/null/false/0/0.0/""/[]/{}
    /// are falsy; everything else is truthy. Used by `fromBody` to mirror
    /// Python's `a or b` falsy-fallback in the summary/result selection.
    static func pyTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.int(let i)): return i != 0
        case .some(.double(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let o)): return !o.isEmpty
        }
    }

    public static func fromBody(_ body: [String: JSONValue]) -> WorkshopExecutionUpdate {
        func str(_ key: String) -> String? {
            switch body[key] {
            case .some(.string(let s)): return s
            case .some(.null), .none: return nil
            case .some(let other):
                // Python coerces with str(...); mirror for non-string scalars.
                if case .int(let i) = other { return String(i) }
                if case .double(let d) = other { return String(d) }
                if case .bool(let b) = other { return b ? "True" : "False" }
                return nil
            }
        }
        let id = str("id") ?? str("mission_id") ?? ""
        // `summary` is the alias Python reads FIRST for `result`, joined by
        // Python's `or` (FALSY-fallback, not nil-fallback):
        //   str(body.get("summary") or body.get("result") or qm.result or "")
        // So `{"summary": "", "result": "ok"}` must yield "ok" (empty summary is
        // falsy → falls through), and a falsy scalar (false / 0 / null / "")
        // also falls through. gpt-5.5 review finding #1: the earlier `??`
        // (nil-coalescing) diverged — it kept an empty summary over a real
        // result. We pre-select with retired truthiness, then stringify.
        let resultPresent = body["summary"] != nil || body["result"] != nil
        let resultVal: String?
        if resultPresent {
            // Python `summary or result` — first truthy wins; if neither is
            // truthy, the body contribution is "" (qm.result fallback is
            // applied in updateWorkshopExecution against the persisted record).
            if Self.pyTruthy(body["summary"]) {
                resultVal = str("summary") ?? ""
            } else if Self.pyTruthy(body["result"]) {
                resultVal = str("result") ?? ""
            } else {
                resultVal = ""   // present-but-falsy → empty body contribution
            }
        } else {
            resultVal = nil       // absent → leave unchanged
        }
        return WorkshopExecutionUpdate(
            id: id,
            title: body["title"] != nil ? (str("title") ?? "") : nil,
            objective: body["objective"] != nil ? (str("objective") ?? "") : nil,
            status: body["status"] != nil ? (str("status") ?? "") : nil,
            result: resultVal
        )
    }
}

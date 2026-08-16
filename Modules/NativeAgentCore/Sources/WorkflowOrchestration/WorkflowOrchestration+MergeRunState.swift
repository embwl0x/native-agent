import Foundation
import CryptoKit
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps

// MARK: - Merge helpers (shared, pure)

public enum WorkflowMerge {
    /// Reads the `id` field of a workflow object as a string (mirrors
    /// `str(item.get("id"))`, so a missing/non-string id becomes "" / "None"-ish).
    /// Python's `str(None)` == "None"; we mirror that for missing ids so two
    /// id-less records collide the same way they would in Python.
    public static func idKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "None" }
        guard let idv = obj["id"] else { return "None" }
        switch idv {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        default: return "None"
        }
    }

    /// Retired-runtime truthiness for a scalar/collection JSONValue (matches the
    /// `bool(x)`): "" / 0 / 0.0 / false / null / [] / {} are falsey.
    private static func isTruthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Python `str(value)` for the scalar JSON types that can appear in a
    /// timestamp field (mirrors `str(None)`/`str(True)`/`str(123)` etc.).
    private static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return ""  // not expected for timestamp fields
        }
    }

    /// Sort key: `str(updatedAt or createdAt or "")`. Empty string sorts last
    /// in DESC order. Mirrors Python `key=lambda item: str(item.get("updatedAt")
    /// or item.get("createdAt") or "")` — including Python's `or` truthiness
    /// across non-string scalars (a truthy numeric/bool timestamp sorts under
    /// its `str(...)` form, not "").
    public static func sortKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "" }
        if let u = obj["updatedAt"], isTruthy(u) { return pyStr(u) }
        if let c = obj["createdAt"], isTruthy(c) { return pyStr(c) }
        return ""
    }

    /// dict.update merge: overlay `override` keys onto a copy of `base`.
    public static func merge(base: JSONValue, override: JSONValue) -> JSONValue {
        guard case .object(var baseObj) = base else { return base }
        guard case .object(let ovObj) = override else { return base }
        for (k, v) in ovObj { baseObj[k] = v }
        return .object(baseObj)
    }

    /// Full mirror of Runtime.list_workflows merge logic. Returns
    /// (mergedUnsorted, sortedDescending). The caller persists `mergedUnsorted`
    /// and returns `sortedDescending`.
    public static func mergeRegistry(defaults: [JSONValue], saved: [JSONValue]) -> (mergedUnsorted: [JSONValue], sorted: [JSONValue]) {
        // by_id = {str(item.get("id")): item for item in saved}  — last write wins
        var byId: [String: JSONValue] = [:]
        for item in saved { byId[idKey(item)] = item }

        var merged: [JSONValue] = []
        for def in defaults {
            let override = byId[idKey(def)] ?? .object([:])
            merged.append(merge(base: def, override: override))
        }
        let savedIds = Set(merged.map { idKey($0) })
        for item in saved where !savedIds.contains(idKey(item)) {
            merged.append(item)
        }
        // Stable descending sort by sortKey. Swift's sort is not guaranteed
        // stable, but Python's sorted() IS stable; emulate by tagging index.
        let sorted = merged.enumerated()
            .sorted { lhs, rhs in
                let lk = sortKey(lhs.element)
                let rk = sortKey(rhs.element)
                if lk != rk { return lk > rk }      // DESC
                return lhs.offset < rhs.offset       // stable tie-break
            }
            .map { $0.element }
        return (merged, sorted)
    }
}

// MARK: - Run-state helpers (shared, pure) — mirror Runtime state machine

public enum WorkflowRunState {
    /// Mirrors Python `slugify(value)` in the retired daemon:
    ///   slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    ///   return slug[:80] or str(uuid.uuid4())
    /// The `or uuid4()` fallback only fires for an EMPTY slug. A run id is
    /// always non-empty here (callers reject ""), so we never need a random
    /// fallback; an all-symbol id (impossible for a uuid run id) would collapse
    /// to "" — we return "" in that case to stay deterministic/testable, and the
    /// daemon would have produced a random slug it could never read back anyway.
    public static func slugify(_ value: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAllowed {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // .strip("-")
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        // slug[:80]
        if out.count > 80 { out = String(out.prefix(80)) }
        return out
    }

    /// Reads a string-ish field via Python `str(state.get(key))` semantics for
    /// the scalar types that appear in run state. Missing → nil so the caller
    /// can mirror `str(None)` ("None") only where Python actually does so.
    private static func objField(_ state: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let o) = state else { return nil }
        return o[key]
    }

    private static func pyStrOrNone(_ v: JSONValue?) -> JSONValue {
        switch v {
        case .none, .some(.null): return .string("None")
        case .some(.string(let s)): return .string(s)
        case .some(.bool(let b)): return .string(b ? "True" : "False")
        case .some(.int(let i)): return .string(String(i))
        case .some(.double(let d)): return .string(String(d))
        case .some: return .string("")
        }
    }

    /// Mirror of Runtime.workflow_public_run(state). Field-for-field:
    ///   id            = str(state.get("id"))
    ///   workflowId    = str(state.get("workflowId"))
    ///   workflowName  = state.get("workflowName")            (raw passthrough)
    ///   objective     = state.get("objective")               (raw passthrough)
    ///   status        = str(state.get("status"))
    ///   mode          = "execute"
    ///   engineVersion = str(state.get("engineVersion") or "2")
    ///   steps         = state.get("steps") if list else []
    ///   createdAt     = state.get("createdAt")               (raw passthrough)
    ///   completedAt   = state.get("completedAt")             (raw passthrough)
    ///   currentStepIndex = state.get("currentStepIndex")     (raw passthrough)
    ///   approvalId    = state.get("approvalId")              (raw passthrough)
    public static func publicRun(_ state: JSONValue) -> JSONValue {
        let engineRaw = objField(state, "engineVersion")
        // Python: str(state.get("engineVersion") or "2") — falsey → "2".
        let engineVersion: JSONValue
        switch engineRaw {
        case .some(.string(let s)) where !s.isEmpty: engineVersion = .string(s)
        case .some(.int(let i)) where i != 0: engineVersion = .string(String(i))
        case .some(.double(let d)) where d != 0: engineVersion = .string(String(d))
        case .some(.bool(true)): engineVersion = .string("True")
        default: engineVersion = .string("2")
        }
        let steps: JSONValue
        if case .some(.array(let a)) = objField(state, "steps") { steps = .array(a) } else { steps = .array([]) }
        return .object([
            "id": pyStrOrNone(objField(state, "id")),
            "workflowId": pyStrOrNone(objField(state, "workflowId")),
            "workflowName": objField(state, "workflowName") ?? .null,
            "objective": objField(state, "objective") ?? .null,
            "status": pyStrOrNone(objField(state, "status")),
            "mode": .string("execute"),
            "engineVersion": engineVersion,
            "steps": steps,
            "createdAt": objField(state, "createdAt") ?? .null,
            "completedAt": objField(state, "completedAt") ?? .null,
            "currentStepIndex": objField(state, "currentStepIndex") ?? .null,
            "approvalId": objField(state, "approvalId") ?? .null,
            "blockedReason": objField(state, "blockedReason") ?? .null,
            "recoveryRequired": objField(state, "recoveryRequired") ?? .bool(false),
        ])
    }

    // MARK: - v2 state-machine scaffolding (Wave 35 W03, CUTOVER_PLAN §6.117)
    //
    // These pure helpers mirror the DECISION logic of Runtime.continue_workflow_v2
    // / Runtime.evaluate_step_condition. They are
    // ported AHEAD of the live engine so the eventual SwiftNative run-path can be
    // assembled from already-verified building blocks. They do NOT execute any
    // step — `executeWorkflowStep` (the side-effecting dispatcher) and its FOUR
    // missing backing clients are the hard prerequisites that gate the actual
    // flip; see the SwiftNativeWorkflowOrchestrationClient.runWorkflow doc-comment
    // for the full retirement path.

    /// Retired truthiness for a JSONValue (matches `bool(x)`).
    private static func pyBool(_ v: JSONValue?) -> Bool {
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

    /// Mirror of Runtime.evaluate_step_condition(step, variables, outputs):
    ///   condition = str(step.get("condition") or "").strip()
    ///   if not condition: return True
    ///   if condition.startswith("var:"):    return bool(variables.get(condition[4:]))
    ///   if condition.startswith("output:"): return bool(outputs.get(condition[7:]))
    ///   if condition.lower() in {"false","skip","disabled"}: return False
    ///   return True
    /// `step.get("condition") or ""` runs on RAW truthiness, then `str(...)` wraps
    /// the survivor; a falsey condition (missing/""/0/false/[]/{}) degrades to ""
    /// → returns True. The `[4:]`/`[7:]` slices are Python CODE-POINT slices, but
    /// the prefixes are pure ASCII so a UTF-8/scalar slice is identical here.
    public static func evaluateStepCondition(
        step: JSONValue,
        variables: [String: JSONValue],
        outputs: [String: JSONValue]
    ) -> Bool {
        guard case .object(let s) = step else { return true }
        // str(step.get("condition") or "").strip()
        let rawCondition = pyBool(s["condition"]) ? WorkflowCreate.pyStr(s["condition"]) : ""
        let condition = WorkflowCreate.strip(rawCondition)
        if condition.isEmpty { return true }
        if condition.hasPrefix("var:") {
            let key = String(condition.dropFirst(4))
            return pyBool(variables[key])
        }
        if condition.hasPrefix("output:") {
            let key = String(condition.dropFirst(7))
            return pyBool(outputs[key])
        }
        if ["false", "skip", "disabled"].contains(condition.lowercased()) {
            return false
        }
        return true
    }

    /// The decision Runtime.continue_workflow_v2 makes for a single step BEFORE
    /// any side-effecting execution. Pure / exhaustive so the scaffolding can be
    /// unit-tested without the live engine.
    public enum StepDecision: Equatable, Sendable {
        /// Condition evaluated false → emit a "skipped" receipt, advance index,
        /// continue the loop (NO persist, NO return).
        case skip
        /// One or more `dependsOn` ids are not yet in completed_ids → emit a
        /// "blocked" receipt, set status="blocked", persist, RETURN.
        case blocked(missing: [String])
        /// requiresApproval (or kind=="approval") → create an approval request,
        /// emit a "waiting_approval" receipt, persist, RETURN.
        case waitApproval
        /// Plain step → run executeWorkflowStep (with retry), then advance.
        case execute
    }

    /// Mirror of the per-step branch ladder at the top of continue_workflow_v2's
    /// `while index < len(steps)` body:
    ///   1. if not evaluate_step_condition(...) → skip
    ///   2. missing = [d for d in dependsOn if d not in completed_ids]; if missing → blocked
    ///   3. if step.requiresApproval or kind=="approval" → waitApproval
    ///   4. else → execute
    /// `completedIds` is the set of step ids whose receipt.status == "succeeded".
    public static func decideStep(
        step: JSONValue,
        variables: [String: JSONValue],
        outputs: [String: JSONValue],
        completedIds: Set<String>
    ) -> StepDecision {
        if !evaluateStepCondition(step: step, variables: variables, outputs: outputs) {
            return .skip
        }
        guard case .object(let s) = step else { return .execute }
        // depends_on = [str(x) for x in step.get("dependsOn", [])] if list else []
        let dependsOn: [String]
        if case .some(.array(let arr)) = s["dependsOn"] {
            dependsOn = arr.map { WorkflowCreate.pyStr($0) }
        } else {
            dependsOn = []
        }
        let missing = dependsOn.filter { !completedIds.contains($0) }
        if !missing.isEmpty { return .blocked(missing: missing) }
        // if step.get("requiresApproval") or str(step.get("kind") or "") == "approval"
        let kind = pyBool(s["kind"]) ? WorkflowCreate.pyStr(s["kind"]) : ""
        if pyBool(s["requiresApproval"]) || kind == "approval" {
            return .waitApproval
        }
        return .execute
    }

    /// Mirror of continue_workflow_v2's retry clamp:
    ///   retry = step.get("retry") if isinstance(retry, dict) else {}
    ///   max_attempts = max(1, min(5, int(retry.get("maxAttempts")
    ///                                     or retry.get("max_attempts") or 1)))
    /// Returns the clamped attempt budget [1, 5].
    public static func maxAttempts(forStep step: JSONValue) -> Int {
        guard case .object(let s) = step, case .some(.object(let retry)) = s["retry"] else {
            return 1
        }
        // int(retry.get("maxAttempts") or retry.get("max_attempts") or 1)
        let raw: JSONValue
        if pyBool(retry["maxAttempts"]) {
            raw = retry["maxAttempts"]!
        } else if pyBool(retry["max_attempts"]) {
            raw = retry["max_attempts"]!
        } else {
            raw = .int(1)
        }
        // FIDELITY NOTE (gpt-5.5 review, wave 35 W03): Python `int(retry.get(
        // "maxAttempts") or retry.get("max_attempts") or 1)` RAISES on a TRUTHY
        // un-parseable value ("abc", "1.2", a truthy list/dict) → the run route
        // 500s. This helper uses the lenient WorkflowCreate.pyInt, which degrades
        // such a value to 0 → clamps to 1, rather than throwing. That is
        // DELIBERATE: maxAttempts is a pure scaffolding helper NOT yet wired into
        // a live engine, every production caller writes a numeric maxAttempts, and
        // a throwing clamp would complicate the eventual loop assembly. When the
        // SwiftNative engine is built, the strict-raise belongs at the loop layer
        // (mirroring the daemon's 500), not in this clamp. Numeric values, the
        // camel/snake fallback, and the [1,5] clamp ARE faithful.
        let n = WorkflowCreate.pyInt(raw)
        return max(1, min(5, Int(n)))
    }
}

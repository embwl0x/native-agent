import Foundation
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps

// MARK: - Create-side normalization (shared, pure) — mirror Runtime.create_workflow

public enum WorkflowCreate {
    public static let maximumStepCount = 24
    /// Python `value[:n]` slices by Unicode CODE POINTS, not grapheme clusters.
    /// Mirror it exactly so `name[:120]`, `description[:1000]`, `trigger[:200]`,
    /// `title[:160]`, `kind[:80]` are byte-identical across the cutover.
    public static func codepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    /// Python `str.strip()` removes leading/trailing whitespace. Mirror the
    /// daemon's `.strip()` (str.strip with no args strips Python whitespace:
    /// space, \t, \n, \r, \f, \v and a few Unicode spaces). We use
    /// `.whitespacesAndNewlines` which covers the ASCII set the daemon's text
    /// fields actually carry; matching Python's exact Unicode strip set is not
    /// required for workflow names/descriptions.
    public static func strip(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirror of the MODULE-LEVEL `slugify(value)` used by create_workflow
    ///: differs from WorkflowRunState.slugify ONLY in
    /// the empty-slug fallback — here an empty slug becomes `str(uuid.uuid4())`,
    /// exactly like Python `slug[:80] or str(uuid.uuid4())`. The regex
    /// `[^a-z0-9]+` → "-" then `.strip("-")` then `[:80]` is identical.
    public static func slugify(_ value: String, uuid: () -> String) -> String {
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
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 80 { out = String(out.prefix(80)) }
        return out.isEmpty ? uuid() : out
    }

    /// Python `str(x)` for the scalar JSON types a body field can hold.
    /// Mirrors `str(None)` ("None") / `str(True)` ("True") etc. — the daemon
    /// wraps almost every field read in `str(...)` so a non-string value gets
    /// stringified rather than rejected.
    public static func pyStr(_ v: JSONValue?) -> String {
        switch v {
        case .none, .some(.null): return "None"
        case .some(.string(let s)): return s
        case .some(.bool(let b)): return b ? "True" : "False"
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return String(d)
        // A truthy list/dict CAN reach a `str(body.get(...))` field if a caller
        // passes a malformed payload (e.g. id/toolId as an array). Python's
        // `str([...])` / `str({...})` renders the container repr, NOT "". Mirror
        // the repr so byte-fidelity holds for these (gpt-5.5 review finding #4,
        // 2026-06-02).
        case .some(.array(let a)): return pyRepr(.array(a))
        case .some(.object(let o)): return pyRepr(.object(o))
        }
    }

    /// Python `repr()` for a JSON-decoded value, as `str(container)` uses repr on
    /// the elements: strings get single-quoted (Python prefers ' and only switches
    /// to " when the string contains a ' but no "), None/True/False are the Python
    /// keyword forms, numbers stringify plainly, and list/dict use `[...]` / `{...}`
    /// with `, ` separators and `key: value` for dicts (keys repr'd too). This
    /// covers the malformed-payload path faithfully without pulling in a full
    /// Python object model.
    public static func pyRepr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return pyReprString(s)
        case .array(let a):
            return "[" + a.map { pyRepr($0) }.joined(separator: ", ") + "]"
        case .object(let o):
            // Python dicts preserve INSERTION order; JSONValue.object is a Swift
            // Dictionary (unordered). The exact key order of a repr'd dict is not
            // recoverable from an unordered map, so this branch is best-effort for
            // the malformed-payload case only (a dict never legitimately reaches a
            // str() scalar field). Sort keys for determinism.
            let parts = o.keys.sorted().map { k in pyReprString(k) + ": " + pyRepr(o[k]!) }
            return "{" + parts.joined(separator: ", ") + "}"
        }
    }

    /// Python string repr quoting: default single quotes; if the string contains
    /// a single quote but no double quote, Python uses double quotes; otherwise
    /// single quotes with the embedded single quotes backslash-escaped. Backslashes
    /// are escaped first. This matches CPython's `repr(str)` for the common cases.
    private static func pyReprString(_ s: String) -> String {
        let hasSingle = s.contains("'")
        let hasDouble = s.contains("\"")
        let quote: Character = (hasSingle && !hasDouble) ? "\"" : "'"
        // Backslash first, then the common control escapes CPython repr emits
        // (\n \r \t). Other control chars get \xNN in CPython, but the daemon
        // never feeds those through a str() container field — this path only
        // fires for a malformed payload that puts a container in a scalar slot.
        var body = s.replacingOccurrences(of: "\\", with: "\\\\")
        body = body.replacingOccurrences(of: "\n", with: "\\n")
        body = body.replacingOccurrences(of: "\r", with: "\\r")
        body = body.replacingOccurrences(of: "\t", with: "\\t")
        if quote == "'" {
            body = body.replacingOccurrences(of: "'", with: "\\'")
        }
        return "\(quote)\(body)\(quote)"
    }

    /// Python `int(value or 0)` for the timeoutSeconds field: accepts an int,
    /// a float (truncates toward zero), or an int-parseable string; everything
    /// else → 0. Mirrors `int(step.get("timeoutSeconds") or step.get(
    /// "timeout_seconds") or 0)` where the daemon never feeds a non-numeric
    /// string here (the body comes from create payloads), so a parse failure
    /// degrades to 0 rather than raising.
    public static func pyInt(_ v: JSONValue?) -> Int64 {
        switch v {
        case .some(.int(let i)): return i
        case .some(.double(let d)): return Int64(d)  // truncates toward zero
        case .some(.string(let s)):
            if let i = Int64(s.trimmingCharacters(in: .whitespaces)) { return i }
            return 0
        case .some(.bool(let b)): return b ? 1 : 0
        default: return 0
        }
    }

    /// Python `int(value or 0)` with FAITHFUL raise semantics. Python's `int()`:
    ///   • int/bool → the int (True==1, False==0);
    ///   • float → truncated toward zero;
    ///   • str → parsed as a base-10 INTEGER literal (leading/trailing whitespace
    ///     stripped, optional sign); a float-shaped string "1.2" or non-numeric
    ///     "abc" RAISES ValueError; an empty/whitespace string also RAISES;
    ///   • list/dict/None → would raise TypeError (but `or 0` already mapped a
    ///     falsey None/[]/{} to 0 before int() ran; a TRUTHY list/dict reaches
    ///     int() and raises TypeError).
    /// The caller has ALREADY applied the `or 0` chain, so we receive either a
    /// surviving TRUTHY value or the literal `.int(0)` sentinel. We mirror
    /// CPython `int(x)` exactly for what can reach it:
    ///   • int/bool → the int (True==1, False==0);
    ///   • float → truncated toward zero;
    ///   • str → CPython STRIPS leading/trailing Unicode whitespace (space, \t,
    ///     \n, \r, \f, \v and friends), accepts an optional sign + base-10 int
    ///     literal; a float-shaped "1.2", non-numeric "abc", or a
    ///     whitespace-ONLY "   " (which is TRUTHY so it reached int()) RAISES
    ///     ValueError;
    ///   • list/dict → a TRUTHY collection reaching int() raises TypeError
    ///     (a falsey []/{} was collapsed to 0 by the caller's `or 0`).
    public static func pyIntStrict(_ v: JSONValue?) throws -> Int64 {
        switch v {
        case .none, .some(.null): return 0          // `or 0` sentinel
        case .some(.int(let i)): return i
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.double(let d)): return Int64(d) // truncates toward zero
        case .some(.string(let s)):
            // CPython int() strips Unicode whitespace (incl. newlines) before
            // parsing — `.whitespacesAndNewlines` covers the ASCII set the daemon
            // sees. A whitespace-only string is TRUTHY (it reached int()) and
            // strips to "", which int("") RAISES on — so do NOT return 0 here.
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int64(trimmed) { return i }
            throw WorkflowOrchestrationError.invalidTimeout(s)  // int("abc"/"1.2"/"   ") raises
        case .some(.array), .some(.object):
            throw WorkflowOrchestrationError.invalidTimeout("non-numeric")
        }
    }

    /// Python `bool(value)` truthiness for a JSONValue (for requiresApproval).
    public static func pyBool(_ v: JSONValue?) -> Bool {
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

    public static func objField(_ body: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let o) = body else { return nil }
        return o[key]
    }

    /// Returns the object at `body[key]` if it IS an object, else nil — mirrors
    /// `body.get(key) if isinstance(body.get(key), dict) else {}`.
    private static func objOrEmpty(_ body: JSONValue, _ key: String) -> [String: JSONValue] {
        if case .some(.object(let o)) = objField(body, key) { return o }
        return [:]
    }

    /// Returns the array at `body[key]` if it IS an array, else nil — mirrors
    /// `body.get(key) if isinstance(body.get(key), list) else []`.
    private static func arrOrEmpty(_ body: JSONValue, _ key: String) -> [JSONValue] {
        if case .some(.array(let a)) = objField(body, key) { return a }
        return []
    }

    /// First non-empty (after str()) of the given body keys, else "" — mirrors
    /// `str(step.get(a) or step.get(b) or "")`. Note: Python `or` short-circuits
    /// on TRUTHINESS, so a present-but-empty-string key falls through to the
    /// next; this checks each `str(...)` against "" the same way.
    private static func firstNonEmpty(_ obj: [String: JSONValue], _ keys: [String]) -> String {
        for k in keys {
            let s = pyStr(obj[k])
            // Python `x or y`: only a TRUTHY x wins. str(None)=="None" is truthy
            // in Python, BUT the daemon writes `str(step.get("x") or step.get("y")
            // or "")` — the `or` runs on the RAW value, then str() wraps the
            // survivor. So a missing key (None) is falsey -> falls through; a
            // present non-empty string wins. Mirror by testing the raw value's
            // truthiness via pyBool, then str() the winner.
            if pyBool(obj[k]) { return s }
        }
        return ""
    }

    /// Mirror of create_workflow's per-step normalization (the retired daemon
    /// 6933-6955). Non-dict steps are dropped. Returns the normalized step
    /// objects in order. `index` is 0-based (Python enumerate), used for the
    /// "Step N+1" / "step-N+1" fallbacks.
    public static func normalizeSteps(_ rawSteps: [JSONValue], uuid: () -> String) throws -> [JSONValue] {
        var out: [JSONValue] = []
        // Python `for index, step in enumerate(steps)` advances `index` across
        // SKIPPED non-dict steps (the `continue` does NOT rewind enumerate). So
        // a non-dict step interleaved between two dicts bumps the human index of
        // every following dict's "Step N" / "step-N" fallback. Mirror that by
        // enumerating the RAW list, not by counting only the dict steps
        // (gpt-5.5 review finding #2, 2026-06-02).
        for (index, raw) in rawSteps.enumerated() {
            guard case .object(let step) = raw else { continue }
            let humanIndex = index + 1
            // title = str(step.get("title") or step.get("name") or f"Step {i+1}").strip()[:160]
            var titleRaw = ""
            if pyBool(step["title"]) { titleRaw = pyStr(step["title"]) }
            else if pyBool(step["name"]) { titleRaw = pyStr(step["name"]) }
            else { titleRaw = "Step \(humanIndex)" }
            let title = codepointPrefix(strip(titleRaw), 160)
            // id = slugify(str(step.get("id") or title or f"step-{i+1}"))
            // Python `or` chain on raw truthiness: step["id"] wins if truthy;
            // else the computed `title` string wins if truthy (non-empty); else
            // the f-string. `title` can be "" only if titleRaw stripped to empty
            // AND neither title/name was truthy — but the f"Step {i+1}" fallback
            // guarantees a non-empty title UNLESS title/name were present but
            // whitespace-only, in which case strip() yields "" and we fall to
            // f"step-{i+1}".
            let idRaw: String
            if pyBool(step["id"]) {
                idRaw = pyStr(step["id"])
            } else if !title.isEmpty {
                idRaw = title
            } else {
                idRaw = "step-\(humanIndex)"
            }
            let stepId = slugify(idRaw, uuid: uuid)
            // kind = str(step.get("kind") or "manual")[:80]
            let kindRaw = pyBool(step["kind"]) ? pyStr(step["kind"]) : "manual"
            let kind = codepointPrefix(kindRaw, 80)
            // dependsOn = [str(x) for x in step.get("dependsOn", [])] if list else []
            let dependsRaw: [JSONValue]
            if case .some(.array(let a)) = step["dependsOn"] { dependsRaw = a } else { dependsRaw = [] }
            let dependsOn: [JSONValue] = dependsRaw.map { .string(pyStr($0)) }
            // retry / rollback / input: dict-or-empty
            let retry = objOrEmpty(raw, "retry")
            let rollback = objOrEmpty(raw, "rollback")
            let input = objOrEmpty(raw, "input")
            // Python: int(step.get("timeoutSeconds") or step.get("timeout_seconds") or 0).
            // The `or` chain runs FIRST on raw truthiness — only the surviving
            // TRUTHY value (or the literal int 0 if both keys are falsey) reaches
            // int(). int() then RAISES ValueError on a non-numeric/float-shaped
            // string (e.g. "abc", "1.2", "   ") and TypeError on a truthy list/dict.
            // Resolve the full `or 0` chain before the strict parse so a FALSEY
            // []/{}/""/0 degrades to 0 (never reaches int()) while a TRUTHY
            // un-parseable value raises (gpt-5.5 review findings #5 + re-review,
            // 2026-06-02).
            let timeoutOrTarget: JSONValue
            if pyBool(step["timeoutSeconds"]) {
                timeoutOrTarget = step["timeoutSeconds"]!
            } else if pyBool(step["timeout_seconds"]) {
                timeoutOrTarget = step["timeout_seconds"]!
            } else {
                timeoutOrTarget = .int(0)  // `... or 0`
            }
            let timeout = try pyIntStrict(timeoutOrTarget)
            out.append(.object([
                "id": .string(stepId),
                "title": .string(title),
                "kind": .string(kind),
                "requiresApproval": .bool(pyBool(step["requiresApproval"])),
                "dependsOn": .array(dependsOn),
                "condition": .string(pyStr(pyBool(step["condition"]) ? step["condition"] : .some(.string("")))),
                "retry": .object(retry),
                "rollback": .object(rollback),
                "timeoutSeconds": .int(timeout),
                "approvalClass": .string(firstNonEmpty(step, ["approvalClass", "approval_class"])),
                "outputKey": .string(firstNonEmpty(step, ["outputKey", "output_key"])),
                "toolId": .string(firstNonEmpty(step, ["toolId", "tool_id"])),
                "serverId": .string(firstNonEmpty(step, ["serverId", "server_id"])),
                "toolName": .string(firstNonEmpty(step, ["toolName", "tool_name"])),
                "action": .string(pyStr(pyBool(step["action"]) ? step["action"] : .some(.string("")))),
                "layer": .string(pyStr(pyBool(step["layer"]) ? step["layer"] : .some(.string("")))),
                "input": .object(input),
            ]))
        }
        return out
    }

    /// Full mirror of Runtime.create_workflow's body→record transform (the pure
    /// part, no IO). Returns (workflowId, record). `now` is the single per-call
    /// timestamp Python stamps on createdAt/updatedAt. `uuid` supplies the
    /// slugify empty-fallback / per-step id fallback (injectable for tests).
    public static func buildRecord(body: JSONValue, now: String, uuid: () -> String) throws -> (id: String, record: JSONValue, stepCount: Int) {
        // name = str(body.get("name") or "Untitled workflow").strip()[:120]
        let nameRaw = pyBool(objField(body, "name")) ? pyStr(objField(body, "name")) : "Untitled workflow"
        let name = codepointPrefix(strip(nameRaw), 120)
        // workflow_id = slugify(str(body.get("id") or name))
        let idSource = pyBool(objField(body, "id")) ? pyStr(objField(body, "id")) : name
        let workflowId = slugify(idSource, uuid: uuid)
        // steps = body.get("steps") if isinstance(body.get("steps"), list) else []
        let rawSteps = arrOrEmpty(body, "steps")
        var normalized = try normalizeSteps(rawSteps, uuid: uuid)
        // if not normalized_steps: default single "plan" router step. Python
        // REASSIGNS normalized_steps here, so len(normalized_steps) is 1 below.
        if normalized.isEmpty {
            normalized = [.object([
                "id": .string("plan"),
                "title": .string("Plan next action"),
                "kind": .string("router"),
                "requiresApproval": .bool(false),
            ])]
        }
        // Never silently amputate a large project. The retired daemon used
        // steps[:24], which made a successfully-saved workflow look complete
        // while losing the tail. Refuse before any registry/activity mutation
        // so the caller can decompose the work explicitly.
        guard normalized.count <= maximumStepCount else {
            throw WorkflowOrchestrationError.tooManySteps(
                count: normalized.count,
                maximum: maximumStepCount
            )
        }
        let stepCount = normalized.count
        // description = str(body.get("description") or "").strip()[:1000]
        let descRaw = pyBool(objField(body, "description")) ? pyStr(objField(body, "description")) : ""
        let description = codepointPrefix(strip(descRaw), 1000)
        // status = str(body.get("status") or "active")
        let status = pyBool(objField(body, "status")) ? pyStr(objField(body, "status")) : "active"
        // trigger = str(body.get("trigger") or "").strip()[:200]
        let triggerRaw = pyBool(objField(body, "trigger")) ? pyStr(objField(body, "trigger")) : ""
        let trigger = codepointPrefix(strip(triggerRaw), 200)
        // New workflows use the durable v2 state machine by default. Explicit
        // v1 remains readable for legacy dry-run compatibility.
        let engineVersion = firstNonEmptyOr(body, ["engineVersion", "engine_version"], fallback: "2")
        // variables = body.get("variables") if isinstance(..., dict) else {}
        let variables = objOrEmpty(body, "variables")
        let record: JSONValue = .object([
            "id": .string(workflowId),
            "name": .string(name),
            "description": .string(description),
            "status": .string(status),
            "trigger": .string(trigger),
            "engineVersion": .string(engineVersion),
            "variables": .object(variables),
            "steps": .array(normalized),
            "createdAt": .string(now),
            "updatedAt": .string(now),
        ])
        return (workflowId, record, stepCount)
    }

    /// First TRUTHY (Python `or`) of body[keys] str()'d, else fallback — used
    /// for `str(a or b or fallback)`.
    private static func firstNonEmptyOr(_ body: JSONValue, _ keys: [String], fallback: String) -> String {
        guard case .object(let o) = body else { return fallback }
        for k in keys where pyBool(o[k]) { return pyStr(o[k]) }
        return fallback
    }
}

/// Historical public spelling retained while the exact eight-pattern contract
/// is single-owned by NativeAgentCore.
public typealias WorkflowRedaction = NativeAgentSecretRedactor

public enum WorkflowOrchestrationError: Error, Equatable, LocalizedError {
    case unknownRunState(String)
    case workflowNotRunnable(id: String, reasons: [String])
    /// Mirrors Python `int("abc")` / `int("1.2")` raising ValueError (and a
    /// truthy list/dict raising TypeError) inside create_workflow's per-step
    /// `int(timeoutSeconds or timeout_seconds or 0)`. The Python route would
    /// return a 500; the native client throws so the caller surfaces the same
    /// failure rather than silently coercing to 0.
    case invalidTimeout(String)
    case tooManySteps(count: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .unknownRunState(let runId):
            return "unknown workflow run state: \(runId)"
        case .workflowNotRunnable(let id, let reasons):
            return "workflow '\(id)' is not runnable: \(reasons.joined(separator: "; "))"
        case .invalidTimeout(let value):
            return "invalid workflow timeout: \(value)"
        case .tooManySteps(let count, let maximum):
            return "workflow has \(count) steps; maximum is \(maximum). Break the project into Desk children or multiple workflows."
        }
    }
}

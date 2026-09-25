import Foundation
import MacControl
import MCPDispatcher
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Tool-output failure-shape heuristic

/// Shared success/failure classification for chat tool envelopes. Lives here
/// (not inside ToolProgressPersistenceBuffer, its original home) because the
/// trace recorder below must classify failures IDENTICALLY to the persisted
/// tool rows — two heuristics would let a dispatch persist as failed in chat
/// history yet trace as ok in events.jsonl.
public enum ChatToolOutcome {
    public static func errorMessage(_ error: any Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? ((error as Any) as? CustomStringConvertible)?.description
            ?? String(describing: error)
        let redacted = ChatSecretRedactor.redactText(raw)
        let home = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSafe = home.isEmpty ? redacted : redacted.replacingOccurrences(of: home, with: "~")
        return String(pathSafe.prefix(2_000))
    }

    /// Fill missing failure evidence at the result boundary; successes pass through unchanged.
    public static func normalizedFailure(_ output: JSONValue) -> JSONValue {
        guard !outputLooksSuccessful(output), !isWaitingOnPerson(output),
              !wasCancelled(output), case .object(var object) = output else { return output }
        func text(_ key: String) -> String? {
            guard case .string(let raw)? = object[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func isCode(_ value: String) -> Bool {
            value.count <= 80 && value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
        }
        func explanations(_ value: JSONValue?) -> [String] {
            switch value {
            case .string(let raw):
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? [] : [value]
            case .object(let detail):
                return ["message", "text", "detail", "error", "reason", "content", "result"].flatMap { explanations(detail[$0]) }
            case .array(let values):
                return values.flatMap { explanations($0) }
            default: return []
            }
        }
        let oldReason = text("reason")
        let code = [text("error_code"), text("errorCode"), oldReason].compactMap { $0 }.first {
            isCode($0) && !["failed", "error"].contains($0)
        } ?? "tool_failed"
        let candidates = ["message", "text", "detail", "error", "content", "result", "fix", "recovery_hint", "hint"].flatMap { explanations(object[$0]) }
        let message = candidates.first { !isCode($0) }
            ?? oldReason.flatMap { isCode($0) ? nil : $0 }
            ?? candidates.first
            ?? oldReason.flatMap { $0 == code ? nil : $0 }
            ?? "The tool failed without providing an explanation."
        // Receipt readers own the meaning of reason/message, including refusal
        // classification. Enrichment must never replace the tool's own fields.
        if object["failure_code"] == nil { object["failure_code"] = .string(code) }
        if object["reason"] == nil { object["reason"] = .string(message) }
        if object["message"] == nil { object["message"] = .string(message) }
        return .object(object)
    }

    public static func failure(error: any Error, tool: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "status": .string("failed"),
            "failure_code": .string("dispatch_error"),
            "reason": .string(errorMessage(error)),
            "error": .string(errorMessage(error)),
        ]
        if let recovery = (error as? LocalizedError)?.recoverySuggestion,
           !recovery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["hint"] = .string(ChatSecretRedactor.redactText(recovery))
        }
        if let gate = error as? AutonomyGateError {
            if case .toolDenied(let reason) = gate {
                object["gate_reason"] = .string(ChatSecretRedactor.redactText(reason))
                if let tool, reason.hasPrefix("autonomy=") || reason.hasPrefix("fileAccess=") {
                    let sentence = ToolNotRunStatus.blockedSentence(reason: reason, tool: tool)
                    object["reason"] = .string(sentence)
                    object["error"] = .string(sentence)
                }
            }
            return normalizedFailure(gate.notRunStatus.reporting(.object(object), tool: tool))
        }
        return normalizedFailure(.object(object))
    }

    public enum ExactResultClass: String, Sendable, Equatable {
        case succeeded
        case failed
        case cancelled
        case timeout
        case unknown
    }

    enum CognitiveResult: String, Sendable, Equatable {
        case succeeded
        case failed
        case unknown
    }

    // Positive terminal receipts emitted by built-in tools. Queueing and
    // scheduling are not evidence that the requested work finished.
    // Keep this vocabulary here; missing or unfamiliar evidence stays unknown.
    static let successStatuses: Set<String> = [
        "completed", "ok", "passed",
        "succeeded", "loaded", "unloaded", "deleted",
        "saved", "updated", "sent", "configured", "already_configured",
        "connected", "disconnected", "replied",
        "reviewed", "withdrawn", "archived", "recorded", "no_change",
    ]

    private static let failureStatuses: Set<String> = [
        "denied", "error", "failed", "failure", "rejected", "refused",
    ]

    static func outputLooksSuccessful(_ output: JSONValue) -> Bool {
        if MCPInvocationOutcome.classify(response: output).providerToolResultIsError {
            return false
        }
        guard case .object(let obj) = output else { return true }
        // A PRESENT key holding JSON `null` is "no error", not an error.
        // `MacControlResult.toJSON()` always emits `"error": null` on success,
        // and `obj["error"] != nil` is true for `.some(.null)` — so every
        // Full-Mac tool (view/click/ax_find/…) traced as failed AND reached
        // the model as `is_error:true` for months (root-caused 2026-08-21
        // from the 08-18 "mac_ax_find 12/12 failed" burst: MacControl's op
        // store had all 12 `completed`). Mirrors `exactResultClass`.
        if let error = obj["error"], error != .null { return false }
        // An explicit boolean failure beside a null error is still a failure
        // (gpt-5.5 review 2026-08-21: `{ok:false, error:null}` must not flip
        // to ok once null stops counting). Mirrors `exactResultClass`.
        if case .bool(false)? = obj["ok"] { return false }
        if case .bool(false)? = obj["success"] { return false }
        // Most non-throwing failures on this surface use status:"failed"/
        // "denied" envelopes with NO "error" key (builder tools, Full-Mac
        // gates, lazy-load misses) — without this they persisted as ok:true
        // and the UI rendered failures as successes (audit 2026-06-09).
        if case .string(let status)? = obj["status"] {
            let s = status.lowercased()
            if failureStatuses.contains(s) { return false }
            // A raised need did not run. Counting it as a successful round let
            // the whole-turn budget renew on a card the person had not touched
            // yet — the same shape as the re-asked CONFIRM above.
            if s == "needs_input" { return false }
        }
        if case .int(let code)? = obj["exit_code"], code != 0 { return false }
        if case .double(let code)? = obj["exit_code"], code != 0 { return false }
        return true
    }

    /// Exact machine-envelope classification for evidence and resident
    /// consequence paths. Unlike `outputLooksSuccessful`, this never treats a
    /// missing status as success. Pending transport, approval, partial, and
    /// ambiguous envelopes stay unknown.
    public static func exactResultClass(_ output: JSONValue) -> ExactResultClass {
        if MCPInvocationOutcome.classify(response: output).providerToolResultIsError {
            return .failed
        }
        // Native in-process tools such as read_file and list_dir return their
        // terminal value directly. Reaching this boundary with a string,
        // array, number, or boolean means dispatch completed; thrown failures
        // have already taken the error path above this classifier. Treating
        // every direct value as unknown made successful perception turns look
        // unverified in Agent's outcome evidence. JSON null alone carries no
        // terminal information and remains unknown. Object envelopes continue
        // through the strict status/error rules below, so accepted,
        // approval, and external-effect states are not promoted.
        guard case .object(let object) = output else {
            return output == .null ? .unknown : .succeeded
        }
        // Explicit failure/refusal/timeout evidence outranks pending states,
        // dry runs, and even an otherwise completed operation record.
        if let error = object["error"], error != .null { return .failed }
        if case .bool(false)? = object["ok"] { return .failed }
        if case .bool(false)? = object["success"] { return .failed }
        if case .bool(true)? = object["isError"] { return .failed }
        if case .bool(true)? = object["is_error"] { return .failed }
        if case .bool(true)? = object["failed"] { return .failed }
        if case .bool(true)? = object["refused"] { return .failed }
        if case .bool(true)? = object["timed_out"] { return .timeout }
        if case .bool(true)? = object["timeout"] { return .timeout }
        let status: String? = {
            guard case .string(let raw)? = object["status"] else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()
        if let status, failureStatuses.contains(status) || status == "blocked" { return .failed }
        if let status, ["timeout", "timed_out"].contains(status) { return .timeout }
        if let exitCode = numericExitCode(object["exit_code"]), exitCode != 0 { return .failed }
        if case .bool(true)? = object["dryRun"] ?? object["dry_run"] { return .unknown }
        // Consult the operation record only after explicit failures are ruled out.
        if let projected = MacControlReceiptOutcome.projecting(envelope: output) {
            switch projected {
            case .succeeded: break // Explicit failure markers still veto success.
            case .failed, .refused: return .failed
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .running, .effectUnconfirmed: return .unknown
            }
        }

        let pendingStatuses: Set<String> = [
            "accepted", "attention", "awaiting_approval", "dry_run",
            // `needs_input` is an inline interaction waiting on a person.
            // Nothing ran, nothing failed — it belongs with the other
            // non-terminal envelopes, never with success or failure.
            "needs_input",
            "pending", "pending_approval", "partial", "queued", "scheduled", "ready",
            "running", "started", "waiting", "waiting_approval", "skipped", "submitted", "unknown", "warning",
        ]

        if let status, pendingStatuses.contains(status) { return .unknown }
        if let status, ["cancelled", "canceled"].contains(status) { return .cancelled }
        if let status, successStatuses.contains(status) { return .succeeded }
        if MacControlReceiptOutcome.projecting(envelope: output) == .succeeded { return .succeeded }
        if case .bool(true)? = object["ok"] { return .succeeded }
        if case .bool(true)? = object["success"] { return .succeeded }
        if numericExitCode(object["exit_code"]) == 0 { return .succeeded }
        return .unknown
    }

    /// User, 2026-09-06: a slot the Stop reached NEVER RAN. Its envelope is
    /// synthetic (`SwiftNativeTurnEngine.cancelledToolResult`) and carries an
    /// `error` string only so the model reads a reason — it is not evidence of
    /// an effect, and not evidence of a failure. Every counter that grades a
    /// turn asks this before it grades a record.
    public static func wasCancelled(_ output: JSONValue) -> Bool {
        exactResultClass(output) == .cancelled
    }

    /// User, 2026-09-06: a tool that filed an approval and returned
    /// `waiting_approval` DID NOT RUN. The row is honest as it stands — it is
    /// not a failure — but it is not PROGRESS either, and counting it as one let
    /// a model that kept re-asking for the same CONFIRM renew the whole-turn
    /// budget on every round and run the turn out at the iteration cap.
    public static func isWaitingApproval(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output,
              case .string(let raw)? = object["status"] else { return false }
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == "waiting_approval"
            || status == "awaiting_approval"
            || status == "pending_approval"
    }

    /// The same truth for an inline interaction: a boundary that raised a need
    /// DID NOT RUN. It is waiting on a person, so it is neither progress nor a
    /// failure — the tool loop stops here and the turn suspends, exactly as it
    /// does for an approval, and the no-progress guard must not read a card as
    /// a round that achieved something.
    public static func isWaitingInteraction(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output,
              case .string(let raw)? = object["status"] else { return false }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "needs_input" else { return false }
        // A canonical typed need and nothing else. An envelope that says
        // `needs_input` while carrying an error, `ok: false`, or
        // `isError: true` is a call that FAILED wearing a waiting label, and
        // reading it as a question hid the failure on every surface: the pill
        // drew "needs you", the fold counted it as open, and the trace filed
        // it without an error class. Explicit failure evidence outranks
        // waiting.
        return !carriesFailureEvidence(output)
    }

    /// Explicit evidence, in the envelope itself, that the call did not
    /// succeed. Never prose: only the wire fields the dispatch boundary
    /// actually writes. The single predicate the pill, the chat fold, and the
    /// trace all ask, so the three can never disagree about one row.
    public static func carriesFailureEvidence(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if let error = object["error"], error != .null {
            if case .string(let text) = error {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            } else {
                return true
            }
        }
        if object["ok"] == .bool(false) { return true }
        if object["isError"] == .bool(true) { return true }
        if object["is_error"] == .bool(true) { return true }
        if object["success"] == .bool(false) { return true }
        return false
    }

    /// Either kind of wait: the turn is parked on a person, not on a model.
    public static func isWaitingOnPerson(_ output: JSONValue) -> Bool {
        isWaitingApproval(output) || isWaitingInteraction(output)
    }

    /// User, 2026-09-06: a cancelled envelope whose dispatch HAD STARTED
    /// (`SwiftNativeTurnEngine.interruptedToolResult`). Still not a failure, but
    /// the tool may have written before it unwound, so retry safety counts it
    /// as an effect while the failure counters keep skipping it.
    public static func effectsUnknown(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output,
              case .bool(true)? = object["effects_unknown"] else { return false }
        return true
    }

    /// Generic chat-tool completion must not duplicate an existing motor
    /// owner's consequence. Those domains publish from their canonical read
    /// models; their immediate tool envelope is transport evidence only.
    static func cognitiveResult(tool: String, output: JSONValue) -> CognitiveResult {
        let resultClass = exactResultClass(output)
        // Deterministic policy/input refusals are useful transcript and audit
        // failures, but they are not evidence that the tool implementation is
        // brittle. Keeping them out of resident physiology prevents a correctly
        // enforced sensitive-path fence (or a caller's missing path) from
        // manufacturing a low-confidence tool reflex.
        if isDeterministicRefusal(output) {
            return .unknown
        }
        // External protocol responses prove only that transport returned.
        // They do not prove that any external effect settled, and a timeout or
        // stream loss may occur after submission. Keep resident physiology
        // neutral; the model and trace still receive the exact result/error.
        if ToolCausalBoundary.isExternalProtocolTool(tool) {
            return .unknown
        }
        if hasCanonicalMotorOwner(tool) {
            // Once the envelope carries the canonical owner's identity, its
            // read model is the only consequence source. Before admission no
            // owner exists, so an exact failure must still reach resident
            // attention instead of disappearing behind the tool-name rule.
            guard canonicalMotorOwnerReference(tool: tool, output: output) == nil else {
                return .unknown
            }
            switch resultClass {
            case .failed, .timeout: return .failed
            case .cancelled, .succeeded, .unknown: return .unknown
            }
        }
        switch resultClass {
        case .succeeded: return .succeeded
        case .failed, .timeout: return .failed
        // User, 2026-09-06: a Stop is not the tool failing. A cancelled slot
        // never reached its implementation, so it is no evidence either way —
        // grading it as a failure manufactured a low-confidence tool reflex out
        // of the user pressing stop.
        case .cancelled: return .unknown
        case .unknown: return .unknown
        }
    }

    /// Bounded, secret-redacted, single-line failure detail for a
    /// failure-shaped envelope — the text a receipt may carry so the NEXT
    /// failure burst is diagnosable from `events.jsonl` alone. Composed ONLY
    /// from error-shaped fields (`error`/`message`/`reason`/`detail`/
    /// `error_code`/`status`), never the result body; `ChatSecretRedactor`
    /// runs BEFORE the cap so a short secret cannot ride through under it.
    /// Returns nil when no such field is set (ok envelopes, bare objects).
    static let failureDetailLimit = 200

    static func failureDetail(_ output: JSONValue) -> String? {
        guard case .object(let object) = output else {
            if case .string(let text) = output { return boundedDetail(text) }
            return nil
        }
        var parts: [String] = []
        func take(_ key: String, label: String? = nil) {
            guard let value = object[key], value != .null else { return }
            let text: String
            switch value {
            case .string(let s): text = s
            case .bool(let b): text = String(b)
            case .int(let i): text = String(i)
            case .double(let d): text = String(d)
            default: return // nested bodies are never summarised
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // The tool loop's projected-error envelope repeats one message
            // under `error` AND `reason`; keep each distinct text once.
            let rendered = label.map { "\($0)=\(trimmed)" } ?? trimmed
            guard !parts.contains(rendered), !parts.contains(trimmed) else { return }
            parts.append(rendered)
        }
        take("error_code", label: "code")
        take("errorCode", label: "code")
        take("failure_code", label: "code")
        take("reason")
        take("status", label: "status")
        take("message")
        take("error")
        take("detail")
        take("fix", label: "fix")
        guard !parts.isEmpty else { return nil }
        return boundedDetail(parts.joined(separator: " | "))
    }

    /// Thrown-error variant: the error's description, same redaction + cap.
    static func failureDetail(error: any Error) -> String {
        failureDetail(failure(error: error)) ?? "The tool failed."
    }

    /// Receipt classification describes the evidence source, not an invented
    /// root cause. A thrown dispatch and a returned failure envelope are
    /// materially different failure paths for investigation.
    static func receiptFailureClass(_ output: JSONValue) -> String {
        switch exactResultClass(output) {
        case .cancelled: return "result_cancelled"
        case .timeout: return "result_timeout"
        case .failed: return "result_failed"
        case .succeeded, .unknown: return "result_failure_envelope"
        }
    }

    private static func boundedDetail(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let redacted = ChatSecretRedactor.redactText(collapsed)
        guard redacted.count > failureDetailLimit else { return redacted }
        return String(redacted.prefix(failureDetailLimit)) + "…"
    }

    private static func isDeterministicRefusal(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if case .bool(true)? = object["requires_approval"] ?? object["requiresApproval"] {
            return true
        }
        if case .bool(true)? = object["permission_denied"] ?? object["permissionDenied"] {
            return true
        }
        if case .string(let rawCode)? = object["error_code"] ?? object["errorCode"] {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let neutralCodes: Set<String> = [
                "approval_required",
                "bad_input",
                "file_not_found",
                "not_loaded",
                "path_not_allowed",
                "permission_denied",
                "policy_denied",
                "security_denied",
                "unsupported",
            ]
            if neutralCodes.contains(code) { return true }
        }
        if case .string(let rawStatus)? = object["status"] {
            let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "awaiting_approval"
                || status == "blocked"
                || status == "pending_approval" {
                return true
            }
            // A typed SecurityCenter denial carries authority evidence beside
            // `status=denied`; an arbitrary domain failure does not.
            if status == "denied",
               object["decision"] != nil
                || object["reasons"] != nil
                || object["capabilities"] != nil {
                return true
            }
        }
        return false
    }

    static func hasCanonicalMotorOwner(_ rawTool: String) -> Bool {
        ToolCausalBoundary.hasCanonicalMotorOwner(tool: rawTool)
    }

    static func canonicalMotorOwnerReference(tool rawTool: String, output: JSONValue) -> String? {
        ToolCausalBoundary.motorReference(tool: rawTool, output: output)?.ownerActionID
    }

    private static func numericExitCode(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let code): return Double(code)
        case .double(let code): return code
        default: return nil
        }
    }
}

// MARK: - ChatToolDispatchTracer

/// Trace-recording ToolDispatchClient. Appends one `tool.dispatch` row to
/// `<dataRoot>/traces/events.jsonl` for EVERY dispatch that flows through it:
/// success, failure-shaped envelope, and thrown error. This keeps
/// `recent_trace_summary` aware of the assistant's own tool activity.
///
/// Wraps the gated chain OUTERMOST (above AutonomyGatedDispatcher /
/// FileAccessGatedDispatcher) so gate denials — which throw before the inner
/// dispatcher runs — still land as status:"failed" rows.
///
/// PRIVACY (hard constraint): rows carry input KEY NAMES, status, duration,
/// and surface only — never argument values or result bodies. The traces
/// file is unencrypted and long-lived.
///
/// Tracing is non-fatal: an IO failure here logs to stderr and the dispatch
/// result (or thrown error) reaches the tool loop unchanged.
///
/// Row schema matches the existing writers (DispatchLedger,
/// NativeClient.appendCapabilityPackTrace):
///   {id, kind, title, status, payload, createdAt} with ISO8601 createdAt.
final class ChatToolDispatchTracer: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let dataRoot: URL
    private let tracesPath: URL
    private let persistence = SwiftNativePersistenceCore()

    init(
        inner: any ToolDispatchClient,
        dataRoot: URL
    ) {
        self.inner = inner
        self.dataRoot = dataRoot
        self.tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Turn Inspector W1: mirror a "begin" event onto the bus the instant
        // the dispatch starts, so the live Inspector shows a tool as RUNNING
        // (not just on completion). Bus-only — the events.jsonl row stays a
        // single end-of-dispatch row, unchanged.
        Self.fireBusEvent(
            tool: tool, input: input, surface: surface,
            phase: "begin", status: "running", durationMs: nil, result: nil
        )
        let result: JSONValue
        do {
            result = ChatToolOutcome.normalizedFailure(try await inner.dispatch(tool: tool, input: input, surface: surface))
        } catch {
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
            Self.fireBusEvent(
                tool: tool, input: input, surface: surface,
                phase: "end", status: "failed", durationMs: durationMs,
                result: ChatToolOutcome.failure(error: error, tool: tool)
            )
            await appendTraceRow(
                tool: tool, input: input, surface: surface,
                status: "failed", startNs: startNs,
                errorClass: "dispatch_threw",
                errorDetail: ChatToolOutcome.failureDetail(error: error)
            )
            throw error
        }
        let ok = ChatToolOutcome.outputLooksSuccessful(result)
        // A raised card is a question to the person, not a failure. It traced
        // as "failed" — with an error class — until 2026-09-14, which is what
        // made the chat fold read "1 of 3 failed" for a card nobody had
        // answered yet. The row stays honest: it is waiting.
        let waiting = !ok && ChatToolOutcome.isWaitingOnPerson(result)
        let status = ok ? "ok" : (waiting ? "waiting" : "failed")
        let failureShaped = !ok && !waiting
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        Self.fireBusEvent(
            tool: tool, input: input, surface: surface,
            phase: "end", status: status, durationMs: durationMs, result: result
        )
        await appendTraceRow(
            tool: tool, input: input, surface: surface,
            status: status, startNs: startNs,
            errorClass: failureShaped ? ChatToolOutcome.receiptFailureClass(result) : nil,
            // Failure-shaped envelope only: an ok or waiting row carries none.
            errorDetail: failureShaped ? ChatToolOutcome.failureDetail(result) : nil
        )
        return result
    }

    /// Turn Inspector W1: fire a tool.dispatch event onto the in-process bus
    /// (fire-and-forget, drop-on-backpressure, NEVER awaited). Carries the tool
    /// name, phase (begin/end), status, duration, and — UNLIKE the privacy-
    /// strict events.jsonl row — a TRUNCATED args/result preview (≤500 chars
    /// each) so the Inspector can show what the tool was called with and what
    /// it returned. The truncation is the redaction-at-emission boundary the
    /// build plan requires; full bodies never reach the bus. Skipped when no
    /// turn is bound.
    private static func fireBusEvent(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        phase: String,
        status: String,
        durationMs: Int?,
        result: JSONValue?
    ) {
        guard TurnTraceContext.turnId != nil else { return }
        var payload: [String: JSONValue] = [
            "name": .string(tool),
            "phase": .string(phase),
            "status": .string(status),
            "argKeys": .array(input.keys.sorted().map { .string($0) }),
            // W2/W3-FIX 4: truncation is not redaction. `mac_keystroke.text`
            // is the literal characters about to be typed and is well under
            // the 500-char preview cap, so the raw secret rode intact onto the
            // TurnTrace bus and into the Inspector. Secret-bearing args are
            // replaced by count + digest BEFORE the preview is built.
            "args": .string(Self.truncatePreview(
                .object(MacInjectionArgRedaction.redacted(tool: tool, input: input))
            )),
        ]
        if let durationMs { payload["durationMs"] = .int(Int64(durationMs)) }
        // Her-screen Phase 4 — "User's screen touched: y/n" for the proof tasks.
        if tool == "act", case .object(let reply)? = result, case .object(let detail)? = reply["detail"],
           let changed = detail["user_front_changed"] {
            payload["user_front_changed"] = changed
        }
        if let result {
            if status == "failed", case .object(let failure) = result {
                // Failure fields bypass the serialized preview, so apply its
                // secret redactor here too, before emission.
                if case .string(let reason)? = failure["reason"] {
                    payload["reason"] = .string(ChatSecretRedactor.redactText(reason))
                }
                payload["errorDetail"] = ChatToolOutcome.failureDetail(result).map(JSONValue.string)
            }
            // W2/W3-FIX-R2 3: redacting the ARGS was half the job. `ax_act`
            // re-reads the element it wrote and returns `element.value` +
            // `post_state.value`, so a password set into a field came back out
            // through the RESULT preview — the same bus, the same Inspector,
            // the same 500-char cap that never truncates a short secret.
            // W3.5-FIX 3 — `mac_view` returns a base64 screenshot of whatever
            // was on screen. The injection redactor above only knows about
            // secret-shaped VALUES, so the picture rode into the bus payload
            // (and from there the Inspector) intact. The full image still goes
            // to the live model call; only this preview loses the pixels.
            payload["result"] = .string(Self.truncatePreview(
                MacInjectionResultRedaction.redacted(
                    tool: tool,
                    result: MacScreenViewResultRedaction.redacted(tool: tool, result: result)
                )
            ))
        }
        TurnTraceBus.fireFromContext(
            kind: "tool.dispatch",
            sessionId: traceSessionID(input),
            surface: surface,
            payload: .object(payload)
        )
        // Turn Inspector W2 — derived file.touch event. When the dispatched
        // tool is a known FILE tool, extract the path argument(s) and fire a
        // file.touch event with {tool, paths, mode}. Fired ONLY on a
        // SUCCESSFUL end (gpt-5.5 W2 review: a thrown/gate-denied dispatch
        // never touched the file — recording it as a touch would be a lie; the
        // failed attempt stays visible as the tool.dispatch end event above).
        // Paths are not secrets but are redacted anyway (cheap, consistent
        // with the redaction-at-emission discipline).
        if phase == "end", status == "ok" {
            Self.fireFileTouchEvent(tool: tool, input: input, surface: surface, status: status)
        }
    }

    /// Turn Inspector W2 — known file-tool catalog → mode map. Names mirror the
    /// real dispatch catalog in ChatOrchestrationClient (SwiftToolDispatcher
    /// fullMacFileToolNames + the always-on read/write file tools + the builder
    /// apply_patch). `read` vs `write` is the dominant access axis; tools that
    /// can do either default to the more sensitive `write` only when they
    /// actually mutate (apply_patch / write_file / file_write). git_* and grep
    /// are reads.
    private static let fileToolModes: [String: String] = [
        "read_file": "read",
        "file_excerpt": "read",
        "list_dir": "read",
        "list_directory": "read",
        "grep": "read",
        "git_status": "read",
        "git_diff": "read",
        "git_log": "read",
        "repo_dirty_summary": "read",
        "write_file": "write",
        "file_write": "write",
        "apply_patch": "write",
    ]

    /// Argument keys that carry a filesystem path across the file-tool catalog.
    /// `apply_patch` carries its target paths INSIDE the patch body (the
    /// envelope itself has no path key), so it contributes no extracted path —
    /// the event still records {tool, mode:write} with an empty paths array,
    /// which is honest (we know it touched files, not which without parsing the
    /// patch — out of W2 scope).
    private static let pathArgKeys: [String] = ["path", "dir", "directory", "file", "filepath", "file_path"]

    private static func fireFileTouchEvent(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String
    ) {
        guard TurnTraceContext.turnId != nil else { return }
        guard let mode = fileToolModes[tool] else { return }
        var paths: [String] = []
        for key in pathArgKeys {
            if case .string(let p)? = input[key], !p.isEmpty {
                // Redact BEFORE bounding (TurnTraceEvent bounds leaves; this
                // adds the secret-scrub half). A path is rarely a secret but a
                // signed URL / token-bearing path would be caught.
                paths.append(ChatSecretRedactor.redactText(p))
            }
        }
        var payload: [String: JSONValue] = [
            "tool": .string(tool),
            "mode": .string(mode),
            "status": .string(status),
            "paths": .array(paths.map { .string($0) }),
        ]
        payload["pathCount"] = .int(Int64(paths.count))
        TurnTraceBus.fireFromContext(
            kind: "file.touch",
            sessionId: traceSessionID(input),
            surface: surface,
            payload: .object(payload)
        )
    }

    private static func traceSessionID(_ input: [String: JSONValue]) -> String? {
        for key in ["__session_id", "session_id", "sessionId"] {
            guard case .string(let raw)? = input[key] else { continue }
            let sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionID.isEmpty { return sessionID }
        }
        return LLMCallContext.sessionId
    }

    /// Serialize a JSONValue to a compact preview string, SECRET-REDACTED
    /// (gpt-5.5 W1 review blocker: truncation alone is not redaction — a
    /// token/password under the limit would persist to turn_traces verbatim),
    /// then truncated to 500 chars. Best-effort: a serialization failure
    /// yields a short marker.
    private static func truncatePreview(_ value: JSONValue) -> String {
        let limit = 500
        let raw: String
        if let data = try? TurnTraceRedactor.redactValue(value).serializedData(pretty: false),
           let s = String(data: data, encoding: .utf8) {
            raw = ChatSecretRedactor.redactText(s)
        } else {
            raw = "[unserializable]"
        }
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "…[+\(raw.count - limit) chars]"
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }

    private func appendTraceRow(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String,
        startNs: UInt64,
        errorClass: String? = nil,
        errorDetail: String? = nil
    ) async {
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        let argKeys = input.keys.sorted()
        let risk = SwiftNativeSecurityCenter.canonicalToolRisk(
            tool: tool,
            input: input,
            dataRoot: dataRoot
        )
        let receipt = CompactActionReceipt.toolDispatch(
            tool: tool,
            surface: surface,
            status: status,
            durationMs: durationMs,
            argKeyCount: argKeys.count,
            risk: risk.rawValue,
            errorClass: errorClass,
            errorDetail: errorDetail
        )
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("tool.dispatch"),
            "title": .string(tool),
            "status": .string(status),
            // Keys only — argument VALUES and result bodies must never land
            // in this file.
            "payload": .object([
                "argKeys": .array(argKeys.map { .string($0) }),
                "durationMs": .int(Int64(durationMs)),
                "surface": .string(surface),
                // Turn Inspector W1: correlate this row to its turn. Unbound
                // (non-turn dispatch) → "unknown".
                "turnId": .string(TurnTraceContext.turnId ?? "unknown"),
                "receipt": receipt.toJSONValue(),
            ]),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        do {
            try await appendPathOwnedJSONL(
                row,
                to: tracesPath,
                using: persistence,
                logLabel: "ChatToolDispatchTracer"
            )
        } catch {
            FileHandle.standardError.write(
                Data("ChatToolDispatchTracer: trace append failed (\(tool)): \(error)\n".utf8)
            )
        }
    }
}

import Foundation
import MacControl
import PersistenceCore
import TurnTrace
import NativeAgentShared
// Blueprint: | `ChatToolOutcome.swift` | exact/display result classes, explanation and common waiting/failure predicates; `projection` gives folds and expanded receipts one interaction-metadata precedence; below ApprovalInbox so readers share classification without importing session persistence |

/// Exact result evidence shared by approvals, transcripts and live turn receipts.
public enum ChatToolOutcome {
    /// The caller refused before execution. Preserve any effects its owner already counted.
    public static func refusedBeforeRunning(_ refusal: JSONValue) -> JSONValue {
        guard case .object(var fields) = refusal, fields["effects"] == nil else { return refusal }
        fields["effects"] = .string("none")
        return .object(fields)
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

    public enum DisplayOutcome: String, Equatable, Sendable {
        case pending = "Running"
        case succeeded = "Completed"
        case refused = "Refused"
        case partial = "Partial"
        case connectionFailed = "Connection failed"
        case unknown = "Outcome unknown"
        case failed = "Failed"
        /// A raised inline card. The call asked the person a question; it did
        /// not fail, and it has not run (2026-09-14).
        case needsYou = "Needs you"
        case asked = "Asked you first"
    }

    public enum FoldStatus: Equatable, Sendable {
        case plain, failed, needsYou, asked
    }

    /// One transcript result for both the fold and the expanded receipt.
    /// Persisted interaction metadata outranks an older raise-time envelope.
    public static func projection(
        kind: String?, ok: Bool?, resultSummary: String?, resultStatus: String? = nil,
        interactionState: String? = nil
    ) -> (status: FoldStatus, outcome: DisplayOutcome) {
        let result = resultSummary.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        guard kind == InlineInteractionWire.transcriptKind else {
            return (ok == false ? .failed : .plain,
                    displayOutcome(result: result, ok: ok, hasResult: resultSummary != nil))
        }
        for recorded in [resultStatus, interactionState] {
            switch (recorded ?? "").lowercased() {
            case "pending", "running": return (.needsYou, .needsYou)
            case "settled", "declined", "superseded", "cancelled": return (.asked, .asked)
            case "failed": return (.failed, .failed)
            default: continue
            }
        }
        guard let result, case .object(let fields) = result,
              case .string(let status)? = fields["status"] else { return (.needsYou, .needsYou) }
        switch status.lowercased() {
        case InlineInteractionWire.waitingStatus, "pending", "running":
            return carriesFailureEvidence(result) ? (.failed, .failed) : (.needsYou, .needsYou)
        case "failed", "error": return (.failed, .failed)
        default: return (.asked, .asked)
        }
    }

    /// Pure projection of the dispatch envelope, never of the transport success bit.
    /// The catch boundary projects AutonomyGateError to these exact wire
    /// forms; do not search arbitrary result prose for errors.
    public static func displayOutcome(result: JSONValue?, ok: Bool?, hasResult: Bool) -> DisplayOutcome {
        guard hasResult else { return ok == false ? .failed : (ok == nil ? .pending : .unknown) }
        guard let value = result else { return ok == false ? .failed : .unknown }
        let classification = ChatToolOutcome.recordedResultClass(value) ?? ChatToolOutcome.exactResultClass(value)
        let macOutcome = MacControlReceiptOutcome.projecting(envelope: value)
        let fields: [String: JSONValue] = { if case .object(let fields) = value { return fields }; return [:] }()
        let status = string(fields["status"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let error = string(fields["error"])
        switch classification {
        case .succeeded:
            if fields["streamClosed"] == .bool(true) { return .connectionFailed }
            if fields["partial"] == .bool(true) { return .partial }
            return .succeeded
        case .refused: return .refused
        case .failed:
            if macOutcome == .refused { return .refused }
            if status == "failed", let error, error.hasPrefix("tool denied: "), fields["reason"] == .string(error) {
                return .refused
            }
            if status == "failed", error == "streamClosed", fields["reason"] == .string("streamClosed") {
                return .connectionFailed
            }
            if fields["streamClosed"] == .bool(true) { return .connectionFailed }
            return .failed
        case .cancelled, .timeout: return .unknown
        case .unknown:
            if fields["streamClosed"] == .bool(true) { return .connectionFailed }
            if ChatToolOutcome.isWaitingInteraction(value) { return .needsYou }
            if status == "partial" || fields["partial"] == .bool(true) { return .partial }
            if status == "running" || macOutcome == .running { return .pending }
            return .unknown
        }
    }

    public static func displaySummary(outcome: DisplayOutcome, input: JSONValue?, result: JSONValue?) -> String {
        let value = result
        let fields: [String: JSONValue] = { if case .object(let fields) = value { return fields }; return [:] }()
        let reason = value.flatMap(ChatToolOutcome.explanation)
        let macOutcome = value.flatMap { MacControlReceiptOutcome.projecting(envelope: $0) }
        switch outcome {
        case .pending: return "No result yet"
        case .asked: return "Asked you first"
        // A question, not a result. The envelope's own one-liner is the reason
        // the card exists, so it is what the pill says.
        case .needsYou:
            return string(fields["detail"]) ?? "Waiting on your answer"
        case .unknown:
            if let macOutcome, macOutcome == .effectUnconfirmed || macOutcome == .timedOut {
                return MacControlReceiptOutcome.effectUnconfirmed.sentence
            }
            return "Response received · completion not confirmed"
        case .connectionFailed: return "Connection lost · completion unknown"
        case .refused:
            if reason == "tool denied: fileAccess=read_only blocks write_file" {
                return "Reading only is allowed; file not written."
            }
            return reason ?? "The request was refused."
        case .partial:
            var count = "Partially completed"
            if case .array(let created)? = fields["created"], case .object(let args)? = input,
               case .array(let children)? = args["children"] {
                count = "\(created.count) of \(children.count) tasks created"
            }
            // Desk breakdown reports "creating child N 'Title': <error>"; say what
            // did not happen and why. The raw reason stays verbatim in Details.
            var why = reason
            if let reason, reason.hasPrefix("creating child "),
               let open = reason.firstIndex(of: "'"),
               let close = reason[reason.index(after: open)...].firstIndex(of: "'") {
                let title = reason[reason.index(after: open)..<close]
                let rest = reason[close...].dropFirst()
                let error = rest.hasPrefix(": ") ? rest.dropFirst(2) : rest
                why = "\(title) not created: \(error)"
            }
            return count + (why.map { " · \($0)" } ?? "")
        case .failed: return reason ?? "The request failed."
        case .succeeded:
            if case .string(let text) = value { return text }
            return string(fields["summary"]) ?? string(fields["message"]) ?? "Completed"
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    public static func explanation(_ output: JSONValue) -> String? {
        sentence(output, keys: ["detail", "message", "summary", "reason", "error"], limit: 600)
    }

    public static func remedy(_ output: JSONValue) -> String? {
        if case .object(let fields) = output, let remedy = fields["remedy"],
           let instruction = sentence(remedy, keys: ["instruction"], limit: 300) {
            return instruction
        }
        return sentence(output, keys: ["remedy", "next_step"], limit: 300)
    }

    private static func sentence(_ output: JSONValue, keys: [String], limit: Int) -> String? {
        guard case .object(let fields) = output else { return nil }
        for key in keys {
            guard case .string(let text)? = fields[key] else { continue }
            let line = TurnTraceRedactor.redactText(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { return String(line.prefix(limit)) }
        }
        return nil
    }

    public static func errorMessage(_ error: any Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? ((error as Any) as? CustomStringConvertible)?.description
            ?? String(describing: error)
        let redacted = TurnTraceRedactor.redactText(raw)
        let home = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSafe = home.isEmpty ? redacted : redacted.replacingOccurrences(of: home, with: "~")
        return String(pathSafe.prefix(2_000))
    }
    public enum ExactResultClass: String, Sendable, Equatable {
        case succeeded
        case failed
        /// A failure that names itself: denied, rejected or refused. Every
        /// reader that grades failure counts it as one.
        case refused
        case cancelled
        case timeout
        case unknown
    }

    // Positive terminal receipts emitted by built-in tools. Queueing and
    // scheduling are not evidence that the requested work finished.
    // Keep this vocabulary here; missing or unfamiliar evidence stays unknown.
    package static let successStatuses: Set<String> = [
        "completed", "ok", "passed",
        "succeeded", "loaded", "unloaded", "deleted",
        "saved", "updated", "sent", "delivered", "configured", "already_configured",
        "connected", "disconnected", "replied",
        "reviewed", "withdrawn", "archived", "recorded", "no_change",
    ]

    package static let failureStatuses: Set<String> = [
        "denied", "error", "failed", "failure", "rejected", "refused", "blocked", "unavailable", "needs_permission", "not_found",
        // A setup this build cannot do, and a send with no route out: nothing ran.
        "not_supported", "no_outbound_route",
    ]

    /// Statuses that are not final: nothing is known to have finished.
    package static let pendingStatuses: Set<String> = [
        "accepted", "attention", "awaiting_approval", "dry_run",
        // `needs_input` is an inline interaction waiting on a person.
        // Nothing ran, nothing failed — it belongs with the other
        // non-terminal envelopes, never with success or failure.
        "needs_input",
        "pending", "pending_approval", "partial", "queued", "scheduled", "ready",
        "running", "started", "waiting", "waiting_approval", "skipped", "submitted", "unknown", "warning",
        // Work whose result is not confirmed: an interrupted hand-off, an
        // effect nobody could read back, a setup waiting on the person.
        "interrupted", "outcome_unknown", "needs_attention",
    ]

    /// Finality, read once: the envelope's own words that nothing is known to
    /// have finished — a non-final status, a dry run, or an operation record
    /// still running or unconfirmed. `exactResultClass` and the trace's status
    /// word both ask this, so the two can never disagree about an open call.
    package static func saysOutcomeOpen(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return output == .null }
        if case .string(let raw)? = object["status"],
           pendingStatuses.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return true }
        if case .bool(true)? = object["dryRun"] ?? object["dry_run"] { return true }
        switch MacControlReceiptOutcome.projecting(envelope: output) {
        case .running?, .effectUnconfirmed?: return true
        default: return false
        }
    }

    /// The persistence writer's classification for a bounded historical receipt.
    /// Only transcript readers consult this; live results use their own evidence.
    public static func recordedResultClass(_ output: JSONValue) -> ExactResultClass? {
        guard case .object(let object) = output,
              case .string(let projection)? = object["transcript_projection"],
              ["bounded_read_receipt", "bounded_tool_receipt"].contains(projection),
              case .string(let original)? = object["original_result_class"] else { return nil }
        return ExactResultClass(rawValue: original)
    }

    /// Exact machine-envelope classification: the one outcome algebra every
    /// projection reads (`outputLooksSuccessful` is its "did not fail"). It
    /// never treats a missing status as success. Pending transport, approval,
    /// partial, and ambiguous envelopes stay unknown.
    public static func exactResultClass(_ output: JSONValue) -> ExactResultClass {
        if reportsError(output) { return .failed }
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
        let status: String? = {
            guard case .string(let raw)? = object["status"] else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()
        // A tool that says its call completed owns its outcome: a command's
        // exit code and timeout are then the command's answer, not the call's.
        let completed = status.map(successStatuses.contains) == true
        // Explicit failure/refusal/timeout evidence outranks pending states,
        // dry runs, and even an otherwise completed operation record. A
        // refusal says why it failed, so it outranks the generic markers.
        if case .bool(true)? = object["refused"] { return .refused }
        if let status, ["denied", "rejected", "refused"].contains(status) { return .refused }
        if let error = object["error"], error != .null { return .failed }
        if object["outcome"] == .string("unmet") { return .failed }
        if case .bool(false)? = object["ok"] { return .failed }
        if case .bool(false)? = object["success"] { return .failed }
        if case .bool(true)? = object["isError"] { return .failed }
        if case .bool(true)? = object["is_error"] { return .failed }
        if case .bool(true)? = object["failed"] { return .failed }
        if let status, ["cancelled", "canceled", "stopped"].contains(status) { return .cancelled }
        if !completed, case .bool(true)? = object["timed_out"] { return .timeout }
        if case .bool(true)? = object["timeout"] { return .timeout }
        if let status, failureStatuses.contains(status) { return .failed }
        if let status, ["timeout", "timed_out"].contains(status) { return .timeout }
        if !completed, let exitCode = numericExitCode(object["exit_code"]), exitCode != 0 { return .failed }
        // Consult the operation record only after explicit failures are ruled out.
        switch MacControlReceiptOutcome.projecting(envelope: output) {
        case .failed?: return .failed
        case .refused?: return .refused
        case .cancelled?: return .cancelled
        case .timedOut?: return .timeout
        default: break // Running/unconfirmed is finality's; success still faces the vetoes.
        }
        if saysOutcomeOpen(output) { return .unknown }
        if let status, successStatuses.contains(status) { return .succeeded }
        if MacControlReceiptOutcome.projecting(envelope: output) == .succeeded { return .succeeded }
        if case .bool(true)? = object["ok"] { return .succeeded }
        if case .bool(true)? = object["success"] { return .succeeded }
        if numericExitCode(object["exit_code"]) == 0 { return .succeeded }
        return .unknown
    }

    /// An error reported at the envelope's top level, or in the one adapter
    /// layer that wraps a raw result under `result`, fails the call whatever
    /// else it says; arbitrary nested business payloads are not protocol state.
    private static func reportsError(_ output: JSONValue) -> Bool {
        func errorShape(_ object: [String: JSONValue]) -> Bool {
            if case .bool(true)? = object["isError"] { return true }
            if case .bool(false)? = object["ok"] { return true }
            if case .bool(false)? = object["success"] { return true }
            if let error = object["error"], error != .null { return true }
            if case .string(let raw)? = object["status"] {
                return ["denied", "error", "failed", "failure", "rejected"]
                    .contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return false
        }
        guard case .object(let object) = output else { return false }
        if errorShape(object) { return true }
        if case .object(let nested)? = object["result"] { return errorShape(nested) }
        return false
    }

    private static func numericExitCode(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let code): return Double(code)
        case .double(let code): return code
        default: return nil
        }
    }}

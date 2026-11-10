import Foundation
import MacControl
import PersistenceCore
import TurnTrace
import NativeAgentShared
// Blueprint: | `ChatToolOutcome.swift` | `projection`: shared outcome evidence |

public enum ChatToolOutcome {
    /// The caller refused before execution. Preserve any effects its owner already counted.
    public static func refusedBeforeRunning(_ refusal: JSONValue) -> JSONValue {
        guard case .object(var fields) = refusal, fields["effects"] == nil else { return refusal }
        fields["effects"] = .string("none")
        return .object(fields)
    }

    /// A raised need did not run and cannot count as progress or failure.
    public static func isWaitingInteraction(_ output: JSONValue, verdict: ExactResultClass? = nil) -> Bool {
        guard case .object(let object) = output,
              case .string(let raw)? = object["status"] else { return false }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "needs_input" else { return false }
        // Explicit failure evidence outranks a waiting label.
        return (verdict ?? exactResultClass(output)) == .unknown
    }

    /// Only dispatch's explicit wire evidence grades failure, so pills, folds and traces cannot disagree.
    public static func carriesFailureEvidence(_ output: JSONValue) -> Bool {
        exactResultClass(output).isFailure
    }

    /// The start boundary handed unstarted work back for the person's words; completed siblings retain their own receipts.
    public static func isPersonArrivalHandBack(_ output: JSONValue) -> Bool {
        let reply = ToolResult(output)
        guard let status = reply.status else { return false }
        // A step that really failed keeps the provider's error bit, whatever the hand-back says about the rest.
        if case .array(let receipts)? = output.objectValue?["receipts"],
           receipts.contains(where: { exactResultClass($0, inspectWrappedResult: true).isFailure }) { return false }
        return output.objectValue?["reason"] == .string("person_arrival")
            && ["skipped", "partial"].contains(status) && !reply.carriesFailureEvidence
    }

    /// Read values may be unwrapped data; incomplete evidence cannot establish a complete snapshot.
    public static func hasReadEvidence(_ output: JSONValue, completeOnly: Bool = false, verdict: ExactResultClass? = nil) -> Bool {
        let verdict = verdict ?? exactResultClass(output)
        guard verdict == .succeeded || verdict == .unknown, output != .null else { return false }
        guard case .object(let fields) = output else { return true }
        guard fields["needs"] == nil, fields["not_run_status"] == nil else { return false }
        if case .string(let availability)? = fields["source_availability"], availability != "available",
           exactResultClass(.object(["status": .string(availability)])) != .succeeded { return false }
        let partial = fields["status"] == .string("partial") || fields["partial"] == .bool(true)
            || fields["truncated"] == .bool(true) || fields["reply_truncated"] == .bool(true)
            || fields["has_more"] == .bool(true) || fields["more_matches_in_page"] == .bool(true)
            || (fields["coverage"]?.objectValue?["complete_in_declared_scope"] ?? fields["coverage"]?.objectValue?["complete"]) == .bool(false)
        if completeOnly && partial { return false }
        return verdict == .succeeded || partial || (fields["status"] == nil && fields["state"] == nil)
    }

    public enum DisplayOutcome: String, Equatable, Sendable {
        case pending = "Running"
        case succeeded = "Completed"
        case refused = "Refused"
        case partial = "Partial"
        case connectionFailed = "Connection failed"
        case unknown = "Outcome unknown"
        case failed = "Failed"
        /// A raised question card means the call has neither run nor failed.
        case needsYou = "Needs you"
        case asked = "Asked you first"
    }

    public enum FoldStatus: Equatable, Sendable {
        case plain, failed, needsYou, asked
    }

    /// Persisted interaction metadata outranks a raise-time envelope in both fold and receipt.
    public static func projection(
        kind: String?, ok: Bool?, result: JSONValue?, hasResult: Bool, resultStatus: String? = nil,
        interactionState: String? = nil
    ) -> (status: FoldStatus, outcome: DisplayOutcome) {
        guard kind == InlineInteractionWire.transcriptKind else {
            if let result, isPersonArrivalHandBack(result) {
                return (.plain, displayOutcome(result: result, ok: ok, hasResult: hasResult))
            }
            return (ok == false ? .failed : .plain,
                    displayOutcome(result: result, ok: ok, hasResult: hasResult))
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
        let reply = ToolResult(result)
        // This projection historically lowercases without trimming the owner's status.
        guard let ownerStatus = reply.status, status.lowercased() == ownerStatus else { return (.asked, .asked) }
        switch ownerStatus {
        case InlineInteractionWire.waitingStatus, "pending", "running":
            return reply.carriesFailureEvidence ? (.failed, .failed) : (.needsYou, .needsYou)
        case "failed", "error": return (.failed, .failed)
        default: return (.asked, .asked)
        }
    }

    /// Project dispatch evidence, never transport success or arbitrary result prose.
    public static func displayOutcome(result: JSONValue?, ok: Bool?, hasResult: Bool) -> DisplayOutcome {
        guard hasResult else { return ok == false ? .failed : (ok == nil ? .pending : .unknown) }
        guard let value = result else { return ok == false ? .failed : .unknown }
        let reply = ToolResult(value)
        let classification = ChatToolOutcome.recordedResultClass(value) ?? reply.outcome
        let macOutcome = MacControlReceiptOutcome.projecting(envelope: value)
        let fields: [String: JSONValue] = { if case .object(let fields) = value { return fields }; return [:] }()
        // These display distinctions belong to status/string-error envelopes, not state or structured errors.
        let status = fields["status"]?.stringValue == nil ? nil : reply.status
        let error = fields["error"]?.stringValue == nil ? nil : reply.failure
        switch classification {
        case .succeeded:
            if fields["streamClosed"] == .bool(true) { return .connectionFailed }
            if fields["partial"] == .bool(true) { return .partial }
            return .succeeded
        case .refused: return .refused
        case .failed:
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
            if reply.isWaitingInteraction { return .needsYou }
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
        // The envelope's reason explains why the question card exists.
        case .needsYou:
            return fields["detail"]?.stringValue ?? "Waiting on your answer"
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
            // Keep the raw failure reason in Details while naming the failed child in the summary.
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
            return fields["summary"]?.stringValue ?? fields["message"]?.stringValue ?? "Completed"
        }
    }

    public static func explanation(_ output: JSONValue) -> String? {
        sentence(output, keys: ["detail", "message", "summary", "reason", "error"], limit: 600)
    }

    public static func remedy(_ output: JSONValue) -> String? {
        let reply = ToolResult(output)
        if let remedy = reply.remedy,
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
        /// Explicit denial, rejection and refusal count as failures for every reader.
        case refused
        case cancelled
        case timeout
        case unknown

        public var isFailure: Bool { self != .succeeded && self != .unknown }

        public var receipt: (status: String, ok: Bool?, label: String) {
            switch self {
            case .succeeded: ("succeeded", true, "Completed")
            case .failed: ("failed", false, "Failed")
            case .refused: ("refused", false, "Refused")
            case .cancelled: ("cancelled", nil, "Cancelled")
            case .timeout: ("timed_out", false, "Timed out")
            case .unknown: ("outcome_unknown", nil, "Outcome unconfirmed")
            }
        }

        public func receiptFields(recordedStatus: String?, failureDetail: JSONValue) -> [String: JSONValue] {
            let facts = receipt
            var fields: [String: JSONValue] = [
                "status": .string(self == .unknown ? recordedStatus ?? facts.status : facts.status)
            ]
            fields["ok"] = facts.ok.map(JSONValue.bool)
            if facts.ok == false { fields["error"] = failureDetail }
            return fields
        }
    }

    // Only positive terminal receipts prove completion; queueing, scheduling and unfamiliar evidence do not.
    package static let successStatuses: Set<String> = [
        "completed", "ok", "success", "passed",
        "succeeded", "loaded", "unloaded", "deleted",
        "saved", "updated", "sent", "delivered", "configured", "already_configured",
        "connected", "disconnected", "replied", "read",
        "reviewed", "withdrawn", "archived", "recorded", "no_change",
        // The workspace facade's admission: its selected reads and sends end under their own names.
        "prepared",
    ]

    package static let failureStatuses: Set<String> = [
        "denied", "error", "failed", "failure", "rejected", "refused", "blocked", "unavailable", "needs_permission", "not_found",
        // A setup this build cannot do, and a send with no route out: nothing ran.
        "not_supported", "no_outbound_route", "readback_unavailable", "blocked_by_trust", "record_changed", "file_changed",
        "needs_setup", "needs_authentication", "auth-required", "authentication-required", "chat_failed", "no_reply", "reconnect_required",
            "session_unavailable", "needs_topic",
    ]

    /// Non-final statuses cannot establish completion.
    package static let pendingStatuses: Set<String> = [
        "accepted", "attention", "awaiting_approval", "dry_run",
        // An inline question ran nothing and belongs with non-terminal envelopes.
        "needs_input",
        "pending", "pending_approval", "partial", "queued", "scheduled", "ready",
        "running", "started", "waiting", "waiting_approval", "skipped", "submitted", "unknown", "warning",
        // Unconfirmed effects and interrupted handoffs remain non-terminal.
        "interrupted", "outcome_unknown", "needs_attention", "approval_required", "approval_filed", "requires_interaction",
    ]

    /// Classification and trace status share this finality predicate so an open call cannot look finished.
    package static func saysOutcomeOpen(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return output == .null }
        if case .string(let raw)? = object["status"] ?? object["state"],
           pendingStatuses.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return true }
        if case .bool(true)? = object["dryRun"] ?? object["dry_run"] { return true }
        if object["httpStatus"] == .int(202) { return true }
        switch MacControlReceiptOutcome.projecting(envelope: output) {
        case .running?, .effectUnconfirmed?: return true
        default: return false
        }
    }

    /// Only historical transcript readers use the persistence classification; live results use their own evidence.
    public static func recordedResultClass(_ output: JSONValue) -> ExactResultClass? {
        guard case .object(let object) = output,
              case .string(let projection)? = object["transcript_projection"],
              ["bounded_read_receipt", "bounded_tool_receipt"].contains(projection),
              case .string(let original)? = object["original_result_class"] else { return nil }
        return ExactResultClass(rawValue: original)
    }

    /// Every projection shares this classification; pending, partial and ambiguous evidence stays unknown.
    public static func exactResultClass(_ output: JSONValue) -> ExactResultClass {
        exactResultClass(output, inspectWrappedResult: true)
    }

    private static func exactResultClass(_ output: JSONValue, inspectWrappedResult: Bool) -> ExactResultClass {
        // A returned value is the call's answer: a scalar, an array, or an object that names no ending of its own. Null carries no terminal evidence.
        guard case .object(let object) = output else {
            return output == .null ? .unknown : .succeeded
        }
        // Operation evidence is authoritative; transport errors remain diagnostic.
        switch MacControlReceiptOutcome.projecting(envelope: output) {
        case .succeeded?: return .succeeded
        case .failed?: return .failed
        case .refused?: return .refused
        case .cancelled?: return .cancelled
        case .timedOut?: return .timeout
        case .running?, .effectUnconfirmed?: return .unknown
        case nil: break
        }
        if object["receipt_owner"] == .string("applescript"), object["result_class"] == .string("unknown") { return .unknown }
        let status: String? = {
            guard case .string(let raw)? = object["status"] ?? object["state"] else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()
        // A tool that says its call completed owns its outcome: a command's exit code and timeout are then the command's answer, not the call's.
        let completed = status.map(successStatuses.contains) == true
        // For unowned envelopes, explicit failures outrank pending states and dry runs.
        if case .bool(true)? = object["refused"] { return .refused }
        if let status, ["denied", "rejected", "refused"].contains(status) { return .refused }
        if let status, ["cancelled", "canceled", "stopped"].contains(status) { return .cancelled }
        // One adapter wrapper is protocol evidence, not arbitrary nested payloads.
        if inspectWrappedResult, case .object? = object["result"], let result = object["result"] {
            switch exactResultClass(result, inspectWrappedResult: false) {
            case .refused: return .refused
            case .cancelled: return .cancelled
            case .failed: return .failed
            case .timeout: return .timeout
            case .succeeded, .unknown: break
            }
        }
        if let error = object["error"], error != .null,
           error.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true { return .failed }
        if let code = object["error_code"], code != .null, !(status == "partial" && object["ok"] == .bool(true)) { return .failed }
        // A receipt that names its own outcome (Chrome's succeeded / failed / outcome_unknown) owns it, like a status does.
        if object["outcome"] == .string("unmet") || object["outcome"] == .string("failed") { return .failed }
        if object["ok"] == .bool(false) || object["success"] == .bool(false) { return .failed }
        if case .bool(true)? = object["isError"] { return .failed }
        if case .bool(true)? = object["is_error"] { return .failed }
        if case .bool(true)? = object["failed"] { return .failed }
        if !completed, case .bool(true)? = object["timed_out"] { return .timeout }
        if case .bool(true)? = object["timeout"] { return .timeout }
        if let status, failureStatuses.contains(status) { return .failed }
        if let status, ["timeout", "timed_out"].contains(status) { return .timeout }
        if !completed, let exitCode = numericExitCode(object["exit_code"]), exitCode != 0 { return .failed }
        if saysOutcomeOpen(output) { return .unknown }
        // The door stamps execution "executed" only on a call it classed succeeded (AppDoorActions.actionResult); a wrapped plain value has no other
        // status.
        if completed || object["ok"] == .bool(true) || object["success"] == .bool(true)
            || object["outcome"] == .string("succeeded") || object["execution"] == .string("executed") { return .succeeded }
        if numericExitCode(object["exit_code"]) == 0 { return .succeeded }
        // Plain data with no ending named and no effect left unseen. An unfamiliar status word still proves nothing.
        let namesAnEnding = ["status", "state", "outcome", "verification", "original_result_class"].contains { object[$0] != nil }
        return namesAnEnding ? .unknown : .succeeded
    }

    private static func numericExitCode(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let code): return Double(code)
        case .double(let code): return code
        default: return nil
        }
    }}

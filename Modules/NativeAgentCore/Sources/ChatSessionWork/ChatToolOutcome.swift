import Foundation
import MacControl
import MCPDispatcher
import PersistenceCore

/// Exact result evidence shared by transcript projection and live turn receipts.
public enum ChatToolOutcome {
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
            let line = ChatSecretRedactor.redactText(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { return String(line.prefix(limit)) }
        }
        return nil
    }

    public static func errorMessage(_ error: any Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? ((error as Any) as? CustomStringConvertible)?.description
            ?? String(describing: error)
        let redacted = ChatSecretRedactor.redactText(raw)
        let home = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSafe = home.isEmpty ? redacted : redacted.replacingOccurrences(of: home, with: "~")
        return String(pathSafe.prefix(2_000))
    }
    public enum ExactResultClass: String, Sendable, Equatable {
        case succeeded
        case failed
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
        "denied", "error", "failed", "failure", "rejected", "refused", "blocked", "unavailable",
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
    ]

    /// The persistence writer's classification for a bounded historical receipt.
    /// Only transcript readers consult this; live results use their own evidence.
    public static func recordedResultClass(_ output: JSONValue) -> ExactResultClass? {
        guard case .object(let object) = output,
              case .string(let projection)? = object["transcript_projection"],
              ["bounded_read_receipt", "bounded_tool_receipt"].contains(projection),
              case .string(let original)? = object["original_result_class"] else { return nil }
        return ExactResultClass(rawValue: original)
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
        if object["outcome"] == .string("unmet") { return .failed }
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
        if let status, failureStatuses.contains(status) { return .failed }
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

        if let status, pendingStatuses.contains(status) { return .unknown }
        if let status, ["cancelled", "canceled"].contains(status) { return .cancelled }
        if let status, successStatuses.contains(status) { return .succeeded }
        if MacControlReceiptOutcome.projecting(envelope: output) == .succeeded { return .succeeded }
        if case .bool(true)? = object["ok"] { return .succeeded }
        if case .bool(true)? = object["success"] { return .succeeded }
        if numericExitCode(object["exit_code"]) == 0 { return .succeeded }
        return .unknown
    }

    private static func numericExitCode(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let code): return Double(code)
        case .double(let code): return code
        default: return nil
        }
    }}

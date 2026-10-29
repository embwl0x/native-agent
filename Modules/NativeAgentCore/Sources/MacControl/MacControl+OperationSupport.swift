import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacControl+OperationSupport.swift` | `SwiftNativeMacControl`: `attachingOperation`, `replayResult`, `unknownResult` |

enum MacControlExecutionSignal: Sendable {
    case result(Result<MacControlResult, Error>)
    case deadline
    case cancellationRequested
}

final class MacControlInFlightExecution: Sendable {
    let task: Task<MacControlResult, Error>
    private let signal = ContinuationOnce<MacControlExecutionSignal>()

    init(task: Task<MacControlResult, Error>) {
        self.task = task
    }

    func wait() async -> MacControlExecutionSignal { await signal.wait() }
    func finish(_ result: Result<MacControlResult, Error>) { signal.resume(.result(result)) }

    func requestCancellation() {
        signal.resume(.cancellationRequested) { task.cancel() }
    }

    func reachDeadline() {
        signal.resume(.deadline) { task.cancel() }
    }
}

final class MacControlInFlightRegistry: @unchecked Sendable {
    static let shared = MacControlInFlightRegistry()
    private let lock = NSLock()
    private var executions: [String: MacControlInFlightExecution] = [:]

    func insert(_ execution: MacControlInFlightExecution, operationId: String) {
        lock.lock()
        executions[operationId] = execution
        lock.unlock()
    }

    func remove(operationId: String) {
        lock.lock()
        executions.removeValue(forKey: operationId)
        lock.unlock()
    }

    func execution(operationId: String) -> MacControlInFlightExecution? {
        lock.lock()
        defer { lock.unlock() }
        return executions[operationId]
    }
}

/// The operation's state and verification own its verdict; transport errors are evidence.
public enum MacControlReceiptOutcome: String, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case refused
    case cancelled
    case timedOut = "timed_out"
    case effectUnconfirmed = "effect_unconfirmed"

    /// The compact human statement for this outcome. Only the unconfirmed case
    /// says anything the transport booleans cannot.
    public var sentence: String {
        switch self {
        case .running: return "Still running"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .refused: return "Refused"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .effectUnconfirmed: return "Outcome unknown; inspect the affected app before another action"
        }
    }

    public static func projecting(
        state: MacControlOperationState?,
        verification: MotorVerificationState?
    ) -> MacControlReceiptOutcome? {
        guard let state else { return nil }
        switch state {
        case .accepted, .started, .cancelRequested: return .running
        case .cancelAcknowledged: return .cancelled
        case .timedOut: return .timedOut
        case .outcomeUnknown: return .effectUnconfirmed
        case .failed: return .failed
        case .blocked, .refused: return .refused
        case .completed:
            switch verification {
            case .failed: return .failed
            case .unverified: return .effectUnconfirmed
            default: return .succeeded
            }
        }
    }

    /// The same projection read off a returned `MacControlResult.toJSON()`
    /// envelope. Returns nil when the envelope carries no operation record, so
    /// non-MacControl tool results keep their existing classification.
    public static func projecting(envelope: JSONValue) -> MacControlReceiptOutcome? {
        guard case .object(let fields) = envelope,
              case .string(let rawState)? = fields["operationState"],
              let state = MacControlOperationState(rawValue: rawState)
        else { return nil }
        let verification: MotorVerificationState? = {
            guard case .string(let raw)? = fields["verification"] else { return nil }
            return MotorVerificationState(rawValue: raw)
        }()
        return projecting(state: state, verification: verification)
    }
}

extension SwiftNativeMacControl {
    static func attachingOperation(
        _ result: MacControlResult,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: result.ok,
            action: result.action,
            output: result.output,
            error: result.error,
            durationMs: result.durationMs,
            httpStatus: result.httpStatus,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification,
            nativePage: result.nativePage
        )
    }

    static func replayResult(_ record: MacControlOperationRecord) -> MacControlResult {
        let ok = record.state == .completed
        let status: Int?
        switch record.state {
        case .blocked, .refused: status = 403
        case .timedOut: status = 408
        case .outcomeUnknown: status = 409
        case .failed: status = 500
        default: status = nil
        }
        return MacControlResult(
            ok: ok,
            action: record.action,
            output: .object([
                "status": .string("idempotent_replay"),
                "operation_state": .string(record.state.rawValue),
            ]),
            error: ok ? nil : record.outcomeCode,
            durationMs: 0,
            httpStatus: status,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    static func unknownResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        let cause: String
        switch record.outcomeCode {
        case "restart_interrupted": cause = "NativeAgent restarted before the action's external effect could be verified."
        case "deadline_effect_unknown": cause = "The action's time limit expired before its external effect could be verified."
        case "cancel_effect_unknown": cause = "Cancellation was requested before the action's external effect could be verified."
        default: cause = "The action's external effect could not be verified."
        }
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "status": .string("outcome_unknown"),
                "retryable": .bool(false),
                "reason": .string(record.outcomeCode ?? "mac_action_result_unavailable"),
                "effects": .string("unknown"),
                "detail": .string("Outcome unknown. " + cause),
                "remedy": Repair.reconcile(
                    instruction: "Inspect the affected app from the original request before another action; name it in mac.look args.app if it is not in front.",
                    nextCall: .object(["tool": .string("app"), "input": .object([
                        "action": .string("mac.look"), "args": .object([:]),
                    ])])),
            ]),
            error: record.outcomeCode ?? "mac_action_result_unavailable",
            durationMs: 0,
            httpStatus: 409,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    static func cancelledResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object(["status": .string("cancel_acknowledged")]),
            error: "cancelled",
            durationMs: 0,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    static func timeoutResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "status": .string("timed_out"),
                "timed_out": .bool(true),
            ]),
            error: "Mac Control deadline exceeded",
            durationMs: 0,
            httpStatus: 408,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    static func resultTimedOut(_ result: MacControlResult) -> Bool {
        guard case .object(let object) = result.output,
              case .bool(let timedOut)? = object["timed_out"] else { return false }
        return timedOut
    }

    static func exitOutcomeCode(_ result: MacControlResult) -> String? {
        guard case .object(let object) = result.output,
              case .int(let exit)? = object["exit_code"] else { return nil }
        return "exit_\(exit)"
    }

    static func verificationState(
        action: String,
        result: MacControlResult
    ) -> MotorVerificationState {
        if let verification = result.verification { return verification }
        if resultTimedOut(result) || !result.ok { return .failed }
        if case .object(let object) = result.output,
           case .bool(let verified)? = object["verified"] {
            return verified ? .satisfied : .unverified
        }
        switch action {
        // These reads return observed state. The document read restores its
        // temporary scroll; menu reads never press an item.
        case "file/read", "file/list", "spotlight", "ax_status", "ax_tree", "ax_find",
             "view", "look", "menu", "clipboard_read", "read":
            return .satisfied
        // Posting input or rereading a control does not verify the intended
        // effect. An explicit verified flag (including wake and clipboard
        // write read-back) is handled above, before this default classification.
        case "notify", "file/write", "file/move", "file/trash", "focus_app", "quit_app",
             "applescript", "shell", "keystroke", "click", "scroll", "ax_act", "hand",
             "menu_press", "act", "wake", "nudge":
            return .unverified
        default:
            return .notRequired
        }
    }

}

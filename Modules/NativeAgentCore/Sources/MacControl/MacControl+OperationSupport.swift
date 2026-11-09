import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `MacControl+OperationSupport.swift` | Bounded response waits retain actual-exit ownership, produced output and unknown effects |

enum MacControlExecutionSignal: Sendable, Equatable {
    case result
    case deadline
    case cancellationRequested
}

final class MacControlInFlightExecution: Sendable {
    struct Settlement: Sendable {
        let response: MacControlResult
        let failure: Error?

        var confirmation: Result<Void, Error> {
            if let failure { return .failure(failure) }
            return .success(())
        }
    }

    private struct State: Sendable {
        var settlement: Settlement?
        var waiters: [UUID: ContinuationOnce<Result<Void, Error>>] = [:]
    }

    let task: Task<MacControlResult, Error>
    private let signal = ContinuationOnce<MacControlExecutionSignal>()
    private let state = Mutex(State())
    var settledResult: MacControlResult? { state.withLock { $0.settlement?.response } }

    init(task: Task<MacControlResult, Error>) {
        self.task = task
    }

    func wait(context: MacOperationContext) async -> MacControlExecutionSignal {
        await signal.wait(budget: context.waitBudget, cancellingWith: context.expired ? .deadline : .cancellationRequested,
            onCancel: { self.task.cancel() })
    }
    func finish(_ settlement: Settlement) {
        let waiters = state.withLock {
            $0.settlement = settlement
            let waiters = Array($0.waiters.values)
            $0.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(settlement.confirmation) }
        signal.resume(.result)
    }

    /// Each cancellation caller waits on actual settlement, independently of the original response signal.
    func waitForSettlement() async throws {
        let id = UUID()
        let waiter = ContinuationOnce<Result<Void, Error>>()
        let completed = state.withLock { state -> Settlement? in
            if let settlement = state.settlement { return settlement }
            state.waiters[id] = waiter
            return nil
        }
        if let completed { waiter.resume(completed.confirmation) }
        defer { state.withLock { $0.waiters.removeValue(forKey: id) } }
        try await waiter.wait(cancellingWith: .failure(CancellationError())).get()
    }

    func requestCancellation() {
        signal.resume(.cancellationRequested) { task.cancel() }
    }

}

final class MacControlInFlightRegistry: @unchecked Sendable {
    static let shared = MacControlInFlightRegistry()
    private let lock = NSLock()
    struct Key: Hashable, Sendable {
        let store: URL
        let operationId: String
    }
    private var executions: [Key: MacControlInFlightExecution] = [:]
    // Payload remains in this process, never in the payload-free lifecycle file. Keep the newest 32 settled bodies for idempotent result retrieval.
    private var completed: [Key] = []

    func insert(_ execution: MacControlInFlightExecution, key: Key) {
        lock.lock()
        executions[key] = execution
        lock.unlock()
    }

    func finished(key: Key) {
        lock.withLock {
            completed.append(key)
            while completed.count > 32 {
                executions.removeValue(forKey: completed.removeFirst())
            }
        }
    }

    func execution(key: Key) -> MacControlInFlightExecution? {
        lock.lock()
        defer { lock.unlock() }
        return executions[key]
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

    /// Only unconfirmed outcomes need explanatory wording beyond transport flags.
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

    /// Return nil for envelopes without a Mac operation record so unrelated tool results retain their own classification.
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
    /// A failed lifecycle write is its own failure, never permission to erase what the completed body produced. The raw outcome stays attached here.
    static func settlementFailure(_ error: Error, body: Result<MacControlResult, Error>,
                                  action: String, operationId: String, context: MacOperationContext) -> MacControlResult {
        var output: [String: JSONValue] = ["status": .string("settlement_failed"),
            "effects": .string("unknown"), "settlement_error": .string(error.localizedDescription)]
        switch body {
        case .success(let result): output["body_result"] = result.toJSON(readContent: context.readContent)
        case .failure(let bodyError):
            output["body_error"] = .string(bodyError.localizedDescription)
            let produced: ProcessRunResult?
            if let stopped = bodyError as? ProcessRunCancellation { produced = stopped.result }
            else if let incomplete = bodyError as? ProcessRunIOFailure { produced = incomplete.result }
            else { produced = nil }
            if let produced {
                output["stdout"] = .string(produced.stdout)
                output["stderr"] = .string(produced.stderr)
                output["stdout_truncated"] = .bool(produced.stdoutTruncated)
                output["stderr_truncated"] = .bool(produced.stderrTruncated)
                output["exit_code"] = .int(Int64(produced.exitCode))
                output["timed_out"] = .bool(produced.timedOut)
            }
        }
        return MacControlResult(ok: false, action: action, output: .object(output),
            error: "mac_operation_settlement_failed", durationMs: 0, operationId: operationId,
            verification: .unverified)
    }

    public static func deadlineResult(action: String) -> MacControlResult {
        MacControlResult(ok: false, action: action, output: .object([
            "status": .string("timed_out"), "timed_out": .bool(true),
            "effects": .string("unknown"), "verification": .string("unverified"),
            "detail": .string("""
                The tool call timed out and cancellation was requested. Earlier input or changes may have reached the app; completion was not verified. \
                Inspect the affected app before another action.
                """)
        ]), error: "Mac Control tool-call deadline exceeded", durationMs: 0,
            httpStatus: 408, verification: .unverified)
    }

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
                "result_available": .bool(false),
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
                    instruction: """
                        Inspect the affected app from the original request before another action; name it in mac.look args.app if it is not in front.
                        """,
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
        // These reads return observed state. The document read restores its temporary scroll; menu reads never press an item.
        case "file/read", "file/list", "spotlight", "ax_status", "ax_tree", "ax_find",
             "view", "look", "menu", "clipboard_read", "read":
            return .satisfied
        // Posting input or rereading a control does not verify the intended effect. An explicit verified flag (including wake and clipboard write read-back) is
        // handled above, before this default classification.
        case "notify", "file/write", "file/move", "file/trash", "focus_app", "quit_app",
             "applescript", "shell", "keystroke", "click", "scroll", "ax_act", "hand",
             "menu_press", "act", "wake", "nudge":
            return .unverified
        default:
            return .notRequired
        }
    }

}

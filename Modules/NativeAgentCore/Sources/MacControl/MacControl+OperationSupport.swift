import Foundation
import NativeAgentCore
import PersistenceCore

final class MacControlOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var didResolve = false
    private var continuation: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>?
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return
        }
        didResolve = true
        waiter = continuation
        continuation = nil
        if waiter == nil {
            self.value = value
        }
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didResolve, let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

enum MacControlExecutionSignal: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case deadline
    case cancellationRequested
}

enum MacControlBoundedResult: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case elapsed
}

final class MacControlInFlightExecution: @unchecked Sendable {
    let task: Task<MacControlResult, Error>
    private let signal = MacControlOneShot<MacControlExecutionSignal>()

    init(task: Task<MacControlResult, Error>) {
        self.task = task
    }

    func wait() async -> MacControlExecutionSignal { await signal.wait() }
    func finish(_ result: Result<MacControlResult, Error>) { signal.resolve(.result(result)) }

    func requestCancellation() {
        signal.resolve(.cancellationRequested)
        task.cancel()
    }

    func reachDeadline() {
        signal.resolve(.deadline)
        task.cancel()
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
            viaSwift: result.viaSwift,
            httpStatus: result.httpStatus,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
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
            viaSwift: true,
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
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "status": .string("outcome_unknown"),
                "retryable": .bool(false),
            ]),
            error: "Mac Control stopped waiting, but the external effect could not be verified; do not retry automatically",
            durationMs: 0,
            viaSwift: true,
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
            viaSwift: true,
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
            viaSwift: true,
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

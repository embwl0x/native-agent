import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - SwiftNative impl

private final class MacControlOneShot<Value: Sendable>: @unchecked Sendable {
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

private enum MacControlExecutionSignal: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case deadline
    case cancellationRequested
}

private enum MacControlBoundedResult: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case elapsed
}

private final class MacControlInFlightExecution: @unchecked Sendable {
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

private final class MacControlInFlightRegistry: @unchecked Sendable {
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

public actor SwiftNativeMacControl: MacControlClient {
    private let now: @Sendable () -> Date
    private let notificationCenterAdapter: NotificationCenterAdapter
    private let appleScriptAdapter: AppleScriptAdapter
    private let processAdapter: ProcessAdapter
    private let fileManagerAdapter: FileManagerAdapter
    private let appControlAdapter: AppControlAdapter
    /// Optional live-policy source for the in-process gate pre-flight
    /// (wave 30 W01). `nil` ⇒ pre-flight disabled ⇒ wave-29 behavior. The
    /// daemon remains the execution/approval/receipt authority regardless.
    private let policyProvider: (any MacControlPolicyProvider)?
    /// Optional path to the daemon's `mac_control_audit.jsonl` (wave 32 W03,
    /// CUTOVER_PLAN §6.55 prereq #4). When non-nil AND a gate pre-flight
    /// REFUSES an action in-process, the refusal is appended to this file as a
    /// `_blocked_receipt`-equivalent JSONL row UNDER the shared cross-process
    /// flock — mirroring the daemon's `MacControl._blocked_receipt`
    /// → `_append_audit` write so a Swift-side refusal is
    /// auditable identically to a daemon-side one. `nil` ⇒ no Swift-side audit
    /// write (the wave-31 behavior): the refusal is still correctly SHAPED
    /// (403/blocked), just not logged from Swift. The daemon remains the
    /// execution / approval / receipt authority; this only adds the refusal row.
    private let auditAppendPath: URL?
    private let persistence = SwiftNativePersistenceCore()
    private let operationStore: MacControlOperationStore?

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        notificationCenterAdapter: NotificationCenterAdapter = SystemNotificationCenterAdapter(),
        appleScriptAdapter: AppleScriptAdapter = SystemAppleScriptAdapter(),
        processAdapter: ProcessAdapter = SystemProcessAdapter(),
        fileManagerAdapter: FileManagerAdapter = SystemFileManagerAdapter(),
        appControlAdapter: AppControlAdapter = SystemAppControlAdapter(),
        policyProvider: (any MacControlPolicyProvider)? = nil,
        auditAppendPath: URL? = nil,
        operationStore: MacControlOperationStore? = nil
    ) {
        _ = http
        self.now = now
        self.notificationCenterAdapter = notificationCenterAdapter
        self.appleScriptAdapter = appleScriptAdapter
        self.processAdapter = processAdapter
        self.fileManagerAdapter = fileManagerAdapter
        self.appControlAdapter = appControlAdapter
        self.policyProvider = policyProvider
        self.auditAppendPath = auditAppendPath
        self.operationStore = operationStore
    }

    public func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !macControlAllActions.contains(normalized) {
            throw MacControlError.unknownAction(normalized)
        }
        guard let operationStore else {
            return try await executeAction(normalized, body: body)
        }
        let operationId = body.stringValue("operationId")
            ?? body.stringValue("operation_id")
            ?? UUID().uuidString
        var operationBody = body
        operationBody["operationId"] = .string(operationId)
        let timeoutSeconds = Self.operationTimeoutSeconds(action: normalized, body: body)
        let begin: MacControlOperationBeginOutcome
        do {
            let requestDigest = try MacControlOperationStore.requestDigest(
                action: normalized,
                body: operationBody
            )
            begin = try await operationStore.begin(
                operationId: operationId,
                action: normalized,
                requestDigest: requestDigest,
                deadlineSeconds: timeoutSeconds
            )
        } catch {
            throw MacControlError.operation(error.localizedDescription)
        }
        switch begin {
        case .replay(let record):
            return Self.replayResult(record)
        case .duplicateActive(let record):
            return MacControlResult(
                ok: false,
                action: normalized,
                output: .object([
                    "status": .string("duplicate_active"),
                    "operationId": .string(operationId),
                ]),
                error: "operation already active",
                durationMs: 0,
                viaSwift: true,
                httpStatus: 409,
                operationId: operationId,
                operationState: record.state,
                verification: record.verification
            )
        case .accepted:
            break
        }

        let outcome = await gatePreflightOutcome(action: normalized, body: operationBody)
        if case .refuse(let refused) = outcome {
            let record = try await operationStore.transition(
                operationId: operationId,
                to: .refused,
                verification: .notRequired,
                expectedNextEvidence: nil,
                outcomeCode: "policy_refused"
            )
            return Self.attachingOperation(refused, record: record)
        }

        _ = try await operationStore.transition(
            operationId: operationId,
            to: .started,
            verification: .pending,
            expectedNextEvidence: "Mac Control terminal result"
        )
        let task = Task<MacControlResult, Error> {
            try await self.executeAction(normalized, body: operationBody, gateAlreadyChecked: true)
        }
        let execution = MacControlInFlightExecution(task: task)
        Task { execution.finish(await task.result) }
        let deadlineTask = Task<Void, Never> {
            // Process-backed handlers own the exact timeout themselves. A
            // short grace lets their typed `timedOut` result win. If an adapter
            // cannot acknowledge cancellation within the bounded settlement
            // grace below, the operation becomes explicitly outcome-unknown.
            let nanos = UInt64(timeoutSeconds) * 1_000_000_000 + 250_000_000
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            guard !Task.isCancelled else { return }
            execution.reachDeadline()
        }
        MacControlInFlightRegistry.shared.insert(execution, operationId: operationId)
        defer {
            deadlineTask.cancel()
            MacControlInFlightRegistry.shared.remove(operationId: operationId)
        }
        let signal = await withTaskCancellationHandler {
            await execution.wait()
        } onCancel: {
            execution.requestCancellation()
        }
        switch signal {
        case .result(let result):
            return try await finishKnownOperationResult(
                result,
                action: normalized,
                operationId: operationId,
                trigger: .ordinary
            )
        case .deadline:
            if let result = await Self.boundedResult(of: task) {
                return try await finishKnownOperationResult(
                    result,
                    action: normalized,
                    operationId: operationId,
                    trigger: .deadline
                )
            }
            return try await finishUnknownOperation(
                action: normalized,
                operationId: operationId,
                outcomeCode: "deadline_effect_unknown"
            )
        case .cancellationRequested:
            if let result = await Self.boundedResult(of: task) {
                return try await finishKnownOperationResult(
                    result,
                    action: normalized,
                    operationId: operationId,
                    trigger: .cancellation
                )
            }
            return try await finishUnknownOperation(
                action: normalized,
                operationId: operationId,
                outcomeCode: "cancel_effect_unknown"
            )
        }
    }

    public func cancel(operationId: String) async throws -> MacControlCancellationResult {
        guard let operationStore else {
            throw MacControlError.operation("canonical operation store is not configured")
        }
        guard let current = try await operationStore.record(operationId: operationId) else {
            throw MacControlError.operation("operation not found")
        }
        if current.state.isTerminal {
            return MacControlCancellationResult(
                operationId: operationId,
                state: current.state,
                acknowledged: current.state == .cancelAcknowledged
            )
        }
        if current.state != .cancelRequested {
            _ = try await operationStore.transition(
                operationId: operationId,
                to: .cancelRequested,
                verification: .pending,
                expectedNextEvidence: "Process-group death acknowledgement",
                outcomeCode: "cancel_requested"
            )
        }
        guard let execution = MacControlInFlightRegistry.shared.execution(operationId: operationId) else {
            return MacControlCancellationResult(
                operationId: operationId,
                state: .cancelRequested,
                acknowledged: false
            )
        }
        execution.requestCancellation()
        // The dispatch owner, not the requester, decides whether the work
        // actually stopped, raced to a real completion, or became unknowable.
        // Wait only for the bounded settlement grace; never hang the cancel
        // requester on an adapter that ignores cooperative cancellation.
        var terminal = try await operationStore.record(operationId: operationId)
        for _ in 0..<300 where terminal?.state == .cancelRequested {
            try await Task.sleep(nanoseconds: 5_000_000)
            terminal = try await operationStore.record(operationId: operationId)
        }
        return MacControlCancellationResult(
            operationId: operationId,
            state: terminal?.state ?? .cancelRequested,
            acknowledged: terminal?.state == .cancelAcknowledged
        )
    }

    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        try await operationStore?.motorActionReadModel(actionId: actionId)
    }

    private func executeAction(
        _ normalized: String,
        body: [String: JSONValue],
        gateAlreadyChecked: Bool = false
    ) async throws -> MacControlResult {
        // GATE PRE-FLIGHT (wave 30 W01). When a live policy is available, run
        // the W4 MacControlGate read-only refusal pipeline IN-PROCESS, in the
        // EXACT order the daemon does (_gate master/remote/category → file
        // policy for file_ops), reproducing byte-identical refusal strings.
        // On refusal we short-circuit BEFORE the native handler:
        // a 403-shaped result with viaSwift:true. This is purely subtractive
        // (it can only REFUSE earlier; it never grants what the daemon would
        // deny) so it is safe even with the daemon still owning execution,
        // approval, receipts, and TCC-bridge attribution.
        if !gateAlreadyChecked {
            let outcome = await gatePreflightOutcome(action: normalized, body: body)
            switch outcome {
            case .refuse(let result):
                return result
            case .proceed:
                break
            }
        }
        switch normalized {
        case "notify":      return try await handleNotify(body)
        case "file/read":   return try await handleFileRead(body)
        case "file/write":  return try await handleFileWrite(body)
        case "file/list":   return try await handleFileList(body)
        case "file/move":   return try await handleFileMove(body)
        case "file/trash":  return try await handleFileTrash(body)
        case "applescript": return try await handleAppleScript(body)
        case "focus_app":   return try await handleFocusApp(body)
        case "quit_app":    return try await handleQuitApp(body)
        case "spotlight":   return try await handleSpotlight(body)
        case "shell":       return try await handleShell(body)
        case let action where macControlUnsupportedActions.contains(action):
            return Self.unsupportedResult(action: action)
        default:
            // Defensive — guarded by macControlAllActions check above.
            throw MacControlError.unknownAction(normalized)
        }
    }

    private static func operationTimeoutSeconds(
        action: String,
        body: [String: JSONValue]
    ) -> Int {
        if case .int(let value) = body["timeout"] ?? .null {
            return max(1, min(Int(value), 120))
        }
        if case .double(let value) = body["timeout"] ?? .null, value.isFinite {
            return max(1, min(Int(value), 120))
        }
        switch action {
        case "spotlight": return 10
        case "shell": return 60
        default: return 90
        }
    }

    private enum OperationSettlementTrigger: Equatable {
        case ordinary
        case deadline
        case cancellation
    }

    /// Cancellation is cooperative for several AppKit / Apple-event adapters.
    /// Wait briefly for a real terminal observation, then stop pretending the
    /// effect is known. The durable unknown state blocks automatic replay.
    private static let settlementGraceNanoseconds: UInt64 = 500_000_000

    private static func boundedResult(
        of task: Task<MacControlResult, Error>
    ) async -> Result<MacControlResult, Error>? {
        let result = MacControlOneShot<MacControlBoundedResult>()
        Task {
            result.resolve(.result(await task.result))
        }
        let timer = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: settlementGraceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            result.resolve(.elapsed)
        }
        let settled = await result.wait()
        timer.cancel()
        switch settled {
        case .result(let value): return value
        case .elapsed: return nil
        }
    }

    private func finishKnownOperationResult(
        _ executionResult: Result<MacControlResult, Error>,
        action: String,
        operationId: String,
        trigger: OperationSettlementTrigger
    ) async throws -> MacControlResult {
        guard let operationStore else {
            return try executionResult.get()
        }
        if let current = try await operationStore.record(operationId: operationId),
           current.state.isTerminal {
            if current.state == .outcomeUnknown {
                return Self.unknownResult(action: action, record: current)
            }
            return Self.replayResult(current)
        }

        switch executionResult {
        case .success(let result):
            if Self.resultTimedOut(result) {
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .timedOut,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "timeout"
                )
                return Self.attachingOperation(result, record: record)
            }
            let verification = Self.verificationState(action: action, result: result)
            let record = try await operationStore.transition(
                operationId: operationId,
                to: result.ok ? .completed : .failed,
                verification: verification,
                expectedNextEvidence: result.ok && verification != .satisfied
                    ? "Separate observation of intended effect"
                    : nil,
                outcomeCode: Self.exitOutcomeCode(result) ?? (result.ok ? "completed" : "handler_failed")
            )
            return Self.attachingOperation(result, record: record)

        case .failure(let error):
            if error is CancellationError {
                if trigger == .deadline {
                    let record = try await operationStore.transition(
                        operationId: operationId,
                        to: .timedOut,
                        verification: .failed,
                        expectedNextEvidence: nil,
                        outcomeCode: "deadline_exceeded_after_stop"
                    )
                    return Self.timeoutResult(action: action, record: record)
                }
                if try await operationStore.record(operationId: operationId)?.state == .started {
                    _ = try await operationStore.transition(
                        operationId: operationId,
                        to: .cancelRequested,
                        verification: .pending,
                        expectedNextEvidence: "Cancellation acknowledgement",
                        outcomeCode: "cancel_requested"
                    )
                }
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .cancelAcknowledged,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "cancelled_before_effect_completion"
                )
                return Self.cancelledResult(action: action, record: record)
            }
            _ = try await operationStore.transition(
                operationId: operationId,
                to: .failed,
                verification: .failed,
                expectedNextEvidence: nil,
                outcomeCode: "execution_failed"
            )
            throw error
        }
    }

    private func finishUnknownOperation(
        action: String,
        operationId: String,
        outcomeCode: String
    ) async throws -> MacControlResult {
        guard let operationStore else {
            throw MacControlError.operation("canonical operation store is not configured")
        }
        if let current = try await operationStore.record(operationId: operationId),
           current.state.isTerminal {
            return current.state == .outcomeUnknown
                ? Self.unknownResult(action: action, record: current)
                : Self.replayResult(current)
        }
        let record = try await operationStore.transition(
            operationId: operationId,
            to: .outcomeUnknown,
            verification: .unknown,
            expectedNextEvidence: "Separate observation of intended effect; do not retry automatically",
            outcomeCode: outcomeCode
        )
        return Self.unknownResult(action: action, record: record)
    }

    private static func attachingOperation(
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

    private static func replayResult(_ record: MacControlOperationRecord) -> MacControlResult {
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

    private static func unknownResult(
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

    private static func cancelledResult(
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

    private static func timeoutResult(
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

    private static func resultTimedOut(_ result: MacControlResult) -> Bool {
        guard case .object(let object) = result.output,
              case .bool(let timedOut)? = object["timed_out"] else { return false }
        return timedOut
    }

    private static func exitOutcomeCode(_ result: MacControlResult) -> String? {
        guard case .object(let object) = result.output,
              case .int(let exit)? = object["exit_code"] else { return nil }
        return "exit_\(exit)"
    }

    private static func verificationState(
        action: String,
        result: MacControlResult
    ) -> MotorVerificationState {
        if resultTimedOut(result) || !result.ok { return .failed }
        if case .object(let object) = result.output,
           case .bool(let verified)? = object["verified"] {
            return verified ? .satisfied : .unverified
        }
        switch action {
        case "file/read", "file/list", "spotlight":
            return .satisfied
        case "notify", "file/write", "file/move", "file/trash", "focus_app", "quit_app", "applescript", "shell":
            return .unverified
        default:
            return .notRequired
        }
    }

    // MARK: gate pre-flight (wave 30 W01)

    /// Outcome of the gate pre-flight. Distinguishes the three states the
    /// dispatcher must handle differently:
    ///   • `.refuse`            — gate denied; return the 403-shaped result.
    ///   • `.proceed`           — gate allowed (or no provider / self_test):
    ///                            continue to the native/unsupported path.
    private enum GatePreflightOutcome {
        case refuse(MacControlResult)
        case proceed
    }

    private static let developerModeOnlyActions: Set<String> = [
        "file/move",
        "file/trash",
        "shell",
        "system",
    ]

    /// Run the W4 `MacControlGate` read-only refusal pipeline in-process.
    ///
    /// Order mirrors the daemon method bodies exactly:
    ///   1. `_gate(category, trigger)` — master → remote_ios → per-category.
    ///   2. For file_ops actions only: `_file_policy_reason(paths…)`.
    ///      (`_sensitive_path_reason` is already enforced by the native file
    ///      handlers' fence; the gate adds the workspace/full-mac file-policy
    ///      layer the fence omits.)
    ///
    /// We do NOT reproduce approval-queue (202), risk-gate session caching,
    /// validate_tool_args, receipt persistence, or TCC-bridge attribution —
    /// those stay daemon-owned. This is strictly a fast-refuse layer.
    private func gatePreflightOutcome(
        action: String,
        body: [String: JSONValue]
    ) async -> GatePreflightOutcome {
        // No provider configured: tests and direct library callers can exercise
        // handlers in isolation. Production wires a Swift TrustCenter provider.
        guard let provider = policyProvider else { return .proceed }
        guard let category = macControlGateCategory(forAction: action) else {
            // self_test / unmapped: no single category to pre-gate. Unsupported
            // actions fail closed after this pre-flight.
            return .proceed
        }
        guard let policy = await provider.currentPolicy() else {
            return .refuse(Self.refusalResult(
                action: action,
                reason: "mac_control_policy_unavailable: Swift trust policy could not be resolved",
                now: now
            ))
        }
        let trigger = body.stringValue("trigger").flatMap { $0.isEmpty ? nil : $0 } ?? "user"

        let decision = MacControlGate.gate(policy, category: category, trigger: trigger)
        if !decision.allowed {
            let result = Self.refusalResult(action: action, reason: decision.reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: decision.reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // file_ops: run the W4 file-policy layer (workspace roots + full-mac
        // window). This reproduces `_file_policy_reason` with byte-identical
        // refusal strings (the W4 port).
        //
        // ORDERING PARITY (W01 round-1 self-review): the daemon checks
        // `_sensitive_path_reason` BEFORE `_file_policy_reason` (read_file
        // L856-859, write_file L894-897, move_file L938-941), so for a path
        // that is BOTH sensitive AND outside-workspace, Python surfaces the
        // SENSITIVE reason. We deliberately do NOT emit the Swift fence's
        // sensitive reason here — its root-form string diverges from the
        // daemon's fully-resolved-root string (a pre-existing wave-29 fence
        // gap). Instead, when a path is sensitive we SKIP the pre-flight
        // file-policy refusal and let it fall through: the native handler's
        // own fence then surfaces the authoritative sensitive reason. This
        // keeps the pre-flight emitting ONLY the verbatim-parity file-policy
        // string, never a divergent sensitive string, while preserving the
        // "sensitive wins over file-policy" precedence.
        let pathKeys = macControlFilePolicyPathKeys(forAction: action)
        if !pathKeys.isEmpty {
            let paths: [String] = pathKeys.compactMap { key in
                guard let v = body.stringValue(key), !v.isEmpty else { return nil }
                return v
            }
            let anySensitive = paths.contains { MacControlSensitivePathFence.reason(forPath: $0) != nil }
            if !anySensitive, !paths.isEmpty,
               let reason = MacControlGate.fileReason(policy, forPaths: paths, now: now()) {
                let result = Self.refusalResult(action: action, reason: reason, now: now)
                await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
                return .refuse(result)
            }
        }
        if Self.developerModeOnlyActions.contains(action),
           !MacControlGate.destructiveActionsAllowed(policy.trustPolicy) {
            let reason = "developer_mode_required: \(action) requires Developer Mode"
            let result = Self.refusalResult(action: action, reason: reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        return .proceed
    }

    /// Build the 403-shaped refusal result. `viaSwift:true` (the refusal was
    /// decided in-process); `httpStatus:403` so NativeClient surfaces a real
    /// 403 to the UI rather than collapsing it. `output.error` carries the
    /// gate reason verbatim so callers can render the daemon-parity message.
    private static func refusalResult(
        action: String,
        reason: String,
        now: @Sendable () -> Date
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("blocked"),
                "error": .string(reason),
                "block_reason": .string(reason),
                "blocked_by": .string("swift_gate_preflight"),
            ]),
            error: reason,
            durationMs: 0,
            viaSwift: true,
            httpStatus: 403
        )
    }

    private static func unsupportedResult(action: String) -> MacControlResult {
        let error = "unsupported_mac_control_action: \(action) is not implemented in Swift"
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("unsupported"),
                "error": .string(error),
                "dispatched_via": .string("swift"),
            ]),
            error: error,
            durationMs: 0,
            viaSwift: true,
            httpStatus: 501
        )
    }

    // MARK: blocked-receipt audit append (wave 32 W03 — CUTOVER §6.55 prereq #4)

    /// Maps a dispatch sub-action to the daemon METHOD name that
    /// `MacControl._blocked_receipt` passes as `method=` (mac_control.py call
    /// sites). Used so a Swift-side refusal audit row carries the SAME `method`
    /// field a daemon-side refusal would, keeping `mac_control_audit.jsonl`
    /// consumers (the GET `/v1/mac_control/audit` reader, any analytics) unable
    /// to tell which process logged the row. Verified against the
    /// `self._blocked_receipt("<method>", "<category>", …)` calls in each
    /// daemon method.
    private static func daemonMethodName(forAction action: String, body: [String: JSONValue]) -> String {
        switch action {
        case "applescript":   return "run_applescript"
        case "jxa":           return "run_jxa"
        case "shortcut",
             "shortcut/run":  return "run_shortcut"
        case "focus_app":     return "focus_app"
        case "quit_app":      return "quit_app"
        case "keystroke":     return "keystroke"
        case "click":         return "click_at"
        case "system":        return systemMethodName(body: body)
        case "file/read":     return "read_file"
        case "file/write":    return "write_file"
        case "file/list":     return "list_directory"
        case "file/move":     return "move_file"
        case "file/trash":    return "trash_file"
        case "notify":        return "post_notification"
        case "shell":         return "run_shell"
        case "spotlight":     return "spotlight_search"
        default:              return action
        }
    }

    /// `/v1/mac_control/system` has NO single daemon method — it fans out to
    /// `set_volume` / `set_brightness` / `sleep_display` / `lock_screen` /
    /// `set_focus_mode` based on the request body's `action` field, and each of
    /// those is the method `_blocked_receipt` records (the retired daemon/839/
    /// 859/870/882). Resolve the concrete method from the body's `action`,
    /// mirroring the daemon route's `_sys_action_id_map`
    ///. Unknown / missing action → `"system"` (the
    /// daemon route would 400 such a request before it ever reached a method;
    /// the generic label is the only honest value when there is no daemon method).
    private static func systemMethodName(body: [String: JSONValue]) -> String {
        let action: String = {
            if case .string(let s)? = body["action"] { return s }
            return ""
        }()
        switch action {
        case "volume", "set_volume": return "set_volume"
        case "brightness":           return "set_brightness"
        case "sleep_display":        return "sleep_display"
        case "lock_screen":          return "lock_screen"
        case "focus_mode":           return "set_focus_mode"
        default:                     return "system"
        }
    }

    /// Byte-faithful port of daemon `MacControl._approval_required(category)`
    ///. Records the SAME `approval_required` value the
    /// daemon's `_blocked_receipt` would write for this refusal:
    ///   • when the live policy carries `approval_required_for`
    ///     (`policy.approvalRequiredFor != nil`), use it verbatim, EXCEPT the
    ///     daemon's `shell` special-case: `"shell" in policy.get(
    ///     "approval_required_for", ["shell"])`. Because the key IS present
    ///     here, the `["shell"]` default does not apply — shell follows the
    ///     list like any other category. (The Python `["shell"]` fallback only
    ///     fires when the key is ABSENT; that maps to the `nil` branch below.)
    ///   • when absent (`nil`): shell → `["shell"]` default ⇒ true; every other
    ///     category → `[]` default ⇒ false. Reproduced exactly.
    private static func approvalRequired(forCategory category: String, policy: MacControlPolicy) -> Bool {
        guard let list = policy.approvalRequiredFor else {
            // Key absent: daemon defaults `shell` → ["shell"], others → [].
            return category == "shell"
        }
        return list.contains(category)
    }

    /// Append a `_blocked_receipt`-equivalent row to `mac_control_audit.jsonl`
    /// under the shared cross-process flock. No-op when `auditAppendPath` is
    /// nil. Best-effort: a write failure is swallowed exactly as the daemon's
    /// `_append_audit` swallows its `except Exception: pass` — the refusal
    /// itself already succeeded; failing to log it must never turn a blocked
    /// action into an executed one.
    ///
    /// Record shape mirrors daemon `make_receipt(method, category, blocked=True,
    /// block_reason=reason, trigger=trigger, approval_required=…)` with
    /// `content` popped (the daemon does `audit_r.pop("content", None)` before
    /// `_append_audit`; blocked receipts never carry `content` anyway). Fields:
    ///   id, method, category, args_hash, trigger, trigger_source,
    ///   approval_required, approved(null), exit_code(0), stdout(""),
    ///   stderr(""), duration_ms(0), executed_at, blocked(true), block_reason.
    ///
    /// BYTE-EQUIVALENCE (wave-33 W02, CUTOVER §6.96). The wave-32 W03 mirror was
    /// FUNCTIONALLY equivalent (right fields, parseable) but NOT byte-equivalent:
    ///   1. Key ORDER: the daemon's `_append_audit` does `json.dumps(receipt)`
    ///      with NO `sort_keys`, so keys land in `make_receipt(...)` insertion
    ///      order (`id` first … `block_reason` last). The Swift mirror went
    ///      through `JSONValue.serialize`, which ALWAYS `sort_keys` (alphabetical
    ///      by UTF-8). Different bytes.
    ///   2. EXTRA `logged_by` key the daemon never writes — a 16th field that
    ///      makes the line non-identical even after fixing order.
    ///   3. `executed_at` format: Swift emitted `…Z` + millis; Python's
    ///      `isoformat()` emits `…+00:00` + microseconds (and `Z` is rejected by
    ///      `datetime.fromisoformat` before Python 3.11).
    /// All three are fixed here: emit the EXACT `make_receipt` field order via
    /// `serializeOrderedObjectPython` (insertion-order, Python default
    /// separators), drop `logged_by`, and format the timestamp as `+00:00` with
    /// 6 fractional digits. Python stays the authority — its on-disk format is
    /// unchanged; the Swift writer conforms to it. (Distinguishing the writer is
    /// not lost: a Swift-logged refusal has `approved=null, exit_code=0,
    /// stdout="", stderr="", duration_ms=0` and is, by construction, only ever a
    /// blocked row — identical to the daemon's own `_blocked_receipt`, which is
    /// the whole point of byte-equivalence.)
    private func emitBlockedAudit(
        action: String,
        category: String,
        reason: String,
        trigger: String,
        policy: MacControlPolicy,
        body: [String: JSONValue]
    ) async {
        guard let path = auditAppendPath else { return }
        // EXACT make_receipt(...) insertion order. Emitting
        // via serializeOrderedObjectPython preserves this order (no sort) and
        // uses Python's default compact separators `(', ', ': ')`.
        let orderedPairs: [(String, JSONValue)] = [
            // Python's make_receipt uses `str(uuid.uuid4())`, which is LOWERCASE.
            // Apple Foundation's `UUID().uuidString` is UPPERCASE — a byte
            // divergence; lowercase it for parity. (gpt-5.5 review finding #1.)
            ("id", .string(UUID().uuidString.lowercased())),
            ("method", .string(Self.daemonMethodName(forAction: action, body: body))),
            ("category", .string(category)),
            // make_receipt sets args_hash="sha256:none" when args is None;
            // _blocked_receipt passes no args, so this matches.
            ("args_hash", .string("sha256:none")),
            ("trigger", .string(trigger)),
            ("trigger_source", .string(trigger)),
            ("approval_required", .bool(Self.approvalRequired(forCategory: category, policy: policy))),
            ("approved", .null),
            ("exit_code", .int(0)),
            ("stdout", .string("")),
            ("stderr", .string("")),
            ("duration_ms", .int(0)),
            ("executed_at", .string(Self.iso8601(now()))),
            ("blocked", .bool(true)),
            ("block_reason", .string(reason)),
        ]
        do {
            let line = try JSONValue.serializeOrderedObjectPython(orderedPairs)
            try await persistence.withFileLock(path) {
                try await persistence.appendAuditLineRaw(line, to: path)
                // M6 (2026-07-09): rotate under the SAME flock as the append —
                // the cap does a read-trim-replace and must not race a
                // concurrent writer. Cannot use appendJSONLCapped here: this
                // feed is byte-equivalent to the daemon's `_append_audit` and
                // must go through appendAuditLineRaw, not JSONValue.serialize.
                let dropped = try enforceJSONLLineCap(at: path, maxLines: JSONLLineCaps.macControlAudit)
                if dropped > 0 {
                    NSLog("MacControl.audit: %@ cap dropped %d oldest line(s)",
                          path.lastPathComponent, dropped)
                }
            }
        } catch {
            // Swallow — parity with daemon `_append_audit` best-effort write.
            // The block already happened; an unloggable refusal must stay a refusal.
        }
    }

    /// ISO-8601 UTC timestamp byte-matching Python's
    /// `datetime.now(timezone.utc).isoformat()`:
    /// `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` — `+00:00` offset (NOT `Z`, which
    /// `datetime.fromisoformat` rejects before Python 3.11) and SIX fractional
    /// digits (microseconds). `ISO8601DateFormatter` only emits millis and a `Z`
    /// suffix, so it cannot reproduce this; build the string by hand.
    ///
    /// MICROSECONDS = TRUNCATION, not round-to-nearest (gpt-5.5 review #3):
    /// Python's epoch→`datetime` conversion floors to integer microseconds, so a
    /// round-to-nearest here would differ by 1µs vs the daemon for the same
    /// instant. To keep the second-component and the micros from EVER disagreeing
    /// at a boundary, derive BOTH from one floored microsecond-since-epoch value:
    /// `wholeSeconds = floor(totalMicros / 1e6)`, `micros = totalMicros % 1e6`,
    /// then format the calendar components from `Date(wholeSeconds)`.
    ///
    /// WHOLE-SECOND CASE (gpt-5.5 review #2, round 2): Python's `isoformat()`
    /// defaults to `timespec='auto'`, which OMITS the fractional part entirely
    /// when `microsecond == 0` (`…07+00:00`, not `…07.000000+00:00`). For any
    /// nonzero microsecond it always prints all 6 digits. Mirror that: emit
    /// `.ffffff` only when `micros != 0`.
    private static func iso8601(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        // Floor to integer microseconds (Python truncates, never rounds up).
        let totalMicros = Int64((interval * 1_000_000).rounded(.down))
        let wholeSeconds = totalMicros / 1_000_000
        let micros = Int(totalMicros % 1_000_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Build components from the FLOORED whole-second instant so the printed
        // second and the micros are taken from the same split — no boundary skew.
        let secondsDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: secondsDate
        )
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        if micros == 0 {
            return base + "+00:00"  // timespec='auto' omits the fraction
        }
        return base + String(format: ".%06d+00:00", micros)
    }

    // MARK: notify

    private func handleNotify(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let title = body.stringValue("title") ?? ""
        let message = body.stringValue("message") ?? ""
        let sound = body.stringValue("sound")
        if title.isEmpty && message.isEmpty {
            throw MacControlError.missingField("title or message")
        }
        let started = now()
        do {
            try await notificationCenterAdapter.postNotification(
                title: title,
                message: message,
                soundName: sound
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "notify",
                output: .object(["title": .string(title), "message": .string(message)]),
                error: "notify failed: \(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "notify",
            output: .object([
                "title": .string(title),
                "message": .string(message),
                "sound": sound.map { .string($0) } ?? .null,
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/read

    private func handleFileRead(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        var maxBytes = 1_000_000
        if case .int(let n) = body["max_bytes"] ?? .null {
            maxBytes = max(1, min(Int(n), 1_000_000))
        } else if case .double(let d) = body["max_bytes"] ?? .null {
            maxBytes = max(1, min(Int(d), 1_000_000))
        }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        // TOCTOU shrink: re-resolve right before the syscall + re-fence.
        // Foundation has no O_NOFOLLOW open, so this still leaves a window
        // between resolve and FileManager open — see fence doc comment.
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content: String
        let rawData: Data
        do {
            rawData = try fileManagerAdapter.readData(at: url, maxBytes: maxBytes)
            // Mirror Python's `errors="replace"`: non-UTF8 bytes become U+FFFD
            // rather than silently producing an empty string.
            content = String(decoding: rawData, as: UTF8.self)
        } catch {
            throw MacControlError.ioFailure("read \(path): \(error)")
        }
        let sha256Hex: String
        #if canImport(CryptoKit)
        sha256Hex = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        #else
        sha256Hex = ""
        #endif
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/read",
            output: .object([
                "path": .string(path),
                "content": .string(content),
                "bytes": .int(Int64(rawData.count)),
                "sha256": .string(sha256Hex),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/write

    private func handleFileWrite(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content = body.stringValue("content") ?? ""
        var append = false
        if case .bool(let b) = body["append"] ?? .null { append = b }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.writeData(
                Data(content.utf8),
                to: url,
                append: append
            )
        } catch {
            throw MacControlError.ioFailure("write \(path): \(error)")
        }
        let verified: Bool = {
            guard let verifier = fileManagerAdapter as? any FileStateVerificationAdapter,
                  verifier.itemExists(at: url),
                  let observed = try? fileManagerAdapter.readData(at: url, maxBytes: 10_000_000) else {
                return false
            }
            let expected = Data(content.utf8)
            return append ? observed.suffix(expected.count) == expected[...] : observed == expected
        }()
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/write",
            output: .object([
                "path": .string(path),
                "bytes": .int(Int64(content.utf8.count)),
                "append": .bool(append),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/list

    private func handleFileList(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let entries: [URL]
        do {
            entries = try fileManagerAdapter.listDirectory(at: url)
        } catch {
            throw MacControlError.ioFailure("list \(path): \(error)")
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        let names = entries.map { JSONValue.string($0.lastPathComponent) }
        return MacControlResult(
            ok: true,
            action: "file/list",
            output: .object([
                "path": .string(path),
                "entries": .array(names),
                "count": .int(Int64(names.count)),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/move

    private func handleFileMove(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let src = body.stringValue("src"), !src.isEmpty else {
            throw MacControlError.missingField("src")
        }
        guard let dst = body.stringValue("dst"), !dst.isEmpty else {
            throw MacControlError.missingField("dst")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.moveItem(from: srcURL, to: dstURL)
        } catch {
            throw MacControlError.ioFailure("move \(src) -> \(dst): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: srcURL) && $0.itemExists(at: dstURL) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/move",
            output: .object([
                "src": .string(src),
                "dst": .string(dst),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/trash

    private func handleFileTrash(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.trashItem(at: url)
        } catch {
            throw MacControlError.ioFailure("trash \(path): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: url) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/trash",
            output: .object([
                "path": .string(path),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: applescript

    private func handleAppleScript(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let script = body.stringValue("script"), !script.isEmpty else {
            throw MacControlError.missingField("script")
        }
        let started = now()
        let result: String
        do {
            result = try await appleScriptAdapter.run(script: script)
        } catch {
            return MacControlResult(
                ok: false,
                action: "applescript",
                output: .object(["script": .string(String(script.prefix(200)))]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "applescript",
            output: .object([
                "script": .string(String(script.prefix(200))),
                "stdout": .string(result),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: focus_app / quit_app

    private func requestedAppName(_ body: [String: JSONValue]) throws -> String {
        let value = body.stringValue("app")
            ?? body.stringValue("name")
            ?? body.stringValue("bundle_id")
            ?? body.stringValue("bundleId")
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacControlError.missingField("app")
        }
        return trimmed
    }

    private func handleFocusApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.focusApp(named: app)
            let ok = result.activated || result.launched
            let observedFrontmost = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isFrontmostApplication(matching: app)
            let verified = ok && observedFrontmost == true
            return MacControlResult(
                ok: ok,
                action: "focus_app",
                output: appControlOutput(
                    result,
                    status: ok ? "focused" : "focus_failed",
                    verified: verified
                ),
                error: ok ? nil : "focus_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "focus_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    private func handleQuitApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.quitApp(named: app)
            let ok = result.terminated || result.alreadyInDesiredState
            let observedRunning = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isApplicationRunning(matching: app)
            let verified = ok && observedRunning == false
            return MacControlResult(
                ok: ok,
                action: "quit_app",
                output: appControlOutput(
                    result,
                    status: ok ? "quit_requested" : "quit_failed",
                    verified: verified
                ),
                error: ok ? nil : "quit_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "quit_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    private func appControlOutput(
        _ result: AppControlRunResult,
        status: String,
        verified: Bool
    ) -> JSONValue {
        .object([
            "requested": .string(result.requestedName),
            "matched_name": result.matchedName.map { .string($0) } ?? .null,
            "bundle_identifier": result.bundleIdentifier.map { .string($0) } ?? .null,
            "process_identifier": result.processIdentifier.map { .int(Int64($0)) } ?? .null,
            "launched": .bool(result.launched),
            "activated": .bool(result.activated),
            "terminated": .bool(result.terminated),
            "already_in_desired_state": .bool(result.alreadyInDesiredState),
            "verified": .bool(verified),
            "status": .string(status),
        ])
    }

    // MARK: spotlight

    private func handleSpotlight(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let query = body.stringValue("query") ?? body.stringValue("q") ?? ""
        if query.isEmpty {
            throw MacControlError.missingField("query")
        }
        var limit = 10
        if case .int(let n) = body["limit"] ?? .null { limit = max(1, min(Int(n), 200)) }
        else if case .double(let d) = body["limit"] ?? .null { limit = max(1, min(Int(d), 200)) }
        let started = now()
        let result = try await processAdapter.run(
            executable: "/usr/bin/mdfind",
            arguments: [query],
            timeoutSeconds: 10
        )
        let lines = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
            // Consult the fence like the file handlers do — raw mdfind hits
            // would otherwise leak paths file read/list refuse to touch.
            .filter { MacControlSensitivePathFence.reason(forPath: $0) == nil }
            .prefix(limit)
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "spotlight",
            output: .object([
                "query": .string(query),
                "results": .array(lines.map { .string($0) }),
                "count": .int(Int64(lines.count)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "spotlight timed out"
                : (result.exitCode == 0 ? nil : "mdfind exit \(result.exitCode) stderr=\(result.stderr.prefix(200))"),
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: shell

    private func handleShell(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let command = body.stringValue("command"), !command.isEmpty else {
            throw MacControlError.missingField("command")
        }
        if let reason = MacControlShellWhitelist.validate(command) {
            throw MacControlError.shellNotWhitelisted(reason)
        }
        var timeout = 60
        if case .int(let n) = body["timeout"] ?? .null { timeout = max(1, min(Int(n), 120)) }
        else if case .double(let d) = body["timeout"] ?? .null { timeout = max(1, min(Int(d), 120)) }
        let started = now()
        let result = try await processAdapter.run(
            executable: "/bin/sh",
            arguments: ["-c", command],
            timeoutSeconds: timeout
        )
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "shell",
            output: .object([
                "command": .string(String(command.prefix(200))),
                "stdout": .string(String(result.stdout.prefix(4000))),
                "stderr": .string(String(result.stderr.prefix(2000))),
                "exit_code": .int(Int64(result.exitCode)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "shell timed out"
                : (result.exitCode == 0 ? nil : "shell exit \(result.exitCode)"),
            durationMs: durationMs,
            viaSwift: true
        )
    }
}

// MARK: - Factory

public func makeMacControl(
    http: any HTTPClient = URLSessionHTTPClient(),
    policyProvider: (any MacControlPolicyProvider)? = nil,
    auditAppendPath: URL? = nil,
    operationDataRoot: URL? = nil
) -> any MacControlClient {
    let dataRoot = operationDataRoot ?? auditAppendPath?.deletingLastPathComponent()
    return SwiftNativeMacControl(
        http: http,
        policyProvider: policyProvider,
        auditAppendPath: auditAppendPath,
        operationStore: dataRoot.map { MacControlOperationStore(dataRoot: $0) }
    )
}

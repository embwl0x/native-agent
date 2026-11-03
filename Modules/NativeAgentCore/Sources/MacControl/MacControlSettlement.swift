import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
// Blueprint: | `MacControlSettlement.swift` | Desktop operation settlement and current refusal audit receipts; incomplete process channels retain output with unknown effects; an unanswered deadline/Stop records unknown effects, never an invented body acknowledgement |

extension SwiftNativeMacControl {
    enum OperationSettlementTrigger: Equatable {
        case ordinary
        case deadline
        case cancellation
    }

    func finishKnownOperationResult(
        _ executionResult: Result<MacControlResult, Error>,
        action: String,
        operationId: String,
        trigger requestedTrigger: OperationSettlementTrigger
    ) async throws -> MacControlResult {
        guard let operationStore else {
            return try executionResult.get()
        }
        let current = try await operationStore.record(operationId: operationId)
        let trigger: OperationSettlementTrigger = current?.outcomeCode == "deadline_effect_unknown" ? .deadline : requestedTrigger
        if let current,
           current.state.isTerminal, current.terminalAt != nil {
            if current.state == .cancelAcknowledged, current.startedAt == nil {
                return Self.cancelledResult(action: action, record: current)
            }
            return Self.attachingOperation(try executionResult.get(), record: current)
        }

        switch executionResult {
        case .success(let result):
            if Self.resultTimedOut(result) {
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .timedOut,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "timeout", settlingActualExit: true
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
                outcomeCode: Self.exitOutcomeCode(result) ?? (result.ok ? "completed" : "handler_failed"), settlingActualExit: true
            )
            return Self.attachingOperation(result, record: record)

        case .failure(let error):
            if error is TaskWaitDeadline.Exceeded {
                let record = try await operationStore.transition(operationId: operationId,
                    to: .outcomeUnknown, verification: .unverified,
                    expectedNextEvidence: "Inspect the affected app before another action",
                    outcomeCode: "deadline_effect_unknown", settlingActualExit: true)
                return Self.attachingOperation(Self.deadlineResult(action: action), record: record)
            }
            if let incomplete = error as? ProcessRunIOFailure {
                let record = try await operationStore.transition(
                    operationId: operationId, to: .outcomeUnknown, verification: .unverified,
                    expectedNextEvidence: "Inspect the affected system before another command",
                    outcomeCode: "process_io_incomplete", settlingActualExit: true)
                return Self.attachingOperation(MacControlResult(ok: false, action: action,
                    output: .object([
                        "status": .string("process_io_incomplete"), "effects": .string("unknown"),
                        "stdout": .string(incomplete.result.stdout), "stderr": .string(incomplete.result.stderr),
                        "stdout_truncated": .bool(incomplete.result.stdoutTruncated),
                        "stderr_truncated": .bool(incomplete.result.stderrTruncated),
                        "exit_code": .int(Int64(incomplete.result.exitCode)),
                        "timed_out": .bool(incomplete.result.timedOut),
                        "channel_errors": .array(incomplete.channels.map(JSONValue.string)),
                        "message": .string(incomplete.localizedDescription)
                    ]), error: "process_io_incomplete", durationMs: 0), record: record)
            }
            if error is CancellationError || error is ProcessRunCancellation {
                let produced = (error as? ProcessRunCancellation).map { stopped in
                    MacControlResult(ok: false, action: action, output: .object([
                        "stdout": .string(stopped.result.stdout), "stderr": .string(stopped.result.stderr),
                        "stdout_truncated": .bool(stopped.result.stdoutTruncated),
                        "stderr_truncated": .bool(stopped.result.stderrTruncated),
                        "exit_code": .int(Int64(stopped.result.exitCode)),
                        "cancelled": .bool(true), "timed_out": .bool(stopped.result.timedOut),
                        "channel_errors": .array(stopped.channels.map(JSONValue.string))
                    ]), error: "process_cancelled", durationMs: 0)
                }
                if trigger == .deadline {
                    let record = try await operationStore.transition(
                        operationId: operationId,
                        to: .timedOut,
                        verification: .failed,
                        expectedNextEvidence: nil,
                        outcomeCode: "deadline_exceeded_after_stop", settlingActualExit: true
                    )
                    return produced.map { Self.attachingOperation($0, record: record) }
                        ?? Self.timeoutResult(action: action, record: record)
                }
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .cancelAcknowledged,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "cancelled_before_effect_completion", settlingActualExit: true
                )
                return produced.map { Self.attachingOperation($0, record: record) }
                    ?? Self.cancelledResult(action: action, record: record)
            }
            let record = try await operationStore.transition(
                operationId: operationId,
                to: .failed,
                verification: .failed,
                expectedNextEvidence: nil,
                outcomeCode: "execution_failed", settlingActualExit: true
            )
            return Self.attachingOperation(MacControlResult(ok: false, action: action,
                output: .object(["status": .string("execution_failed"), "message": .string(error.localizedDescription)]),
                error: error.localizedDescription, durationMs: 0), record: record)
        }
    }

    // MARK: blocked-receipt audit append

    /// Append a refusal under the shared cross-process lock. A failed audit must not turn a refused action into an executed one. Local JSONL evidence: off-disk backup only; no local backup/export/phone copy; PrivacyMap: mac_control_audit.
    func emitBlockedAudit(
        action: String,
        category: String,
        reason: String,
        trigger: String,
        policy _: MacControlPolicy,
        body _: [String: JSONValue]
    ) async {
        guard let path = auditAppendPath else { return }
        let receipt = JSONValue.object([
            "id": .string(UUID().uuidString.lowercased()),
            "method": .string(action),
            "category": .string(category),
            "trigger": .string(trigger),
            "executed_at": .string(NativeTimestampFormat.plainZulu(now())),
            "blocked": .bool(true),
            "block_reason": .string(reason),
        ])
        do {
            let line = try receipt.serialize(pretty: false)
            try await SwiftNativePersistenceCore.withFileLock(path) {
                try await SwiftNativePersistenceCore.appendAuditLineRaw(line, to: path)
                // Retention shares the append lock.
                let dropped = try enforceJSONLRetention(at: path, maxLines: JSONLLineCaps.macControlAudit)
                if dropped > 0 {
                    nativeLog("MacControl.audit: %@ cap dropped %d oldest line(s)",
                          path.lastPathComponent, dropped)
                }
            }
        } catch {
            // The refusal stands, but losing its audit evidence is observable.
            nativeLog("MacControl.audit: refusal record failed (%@)",
                String(error.localizedDescription.prefix(512)))
        }
    }
}

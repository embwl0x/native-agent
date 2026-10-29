import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
// Blueprint: | `MacControlSettlement.swift` | Desktop operation settlement and byte-compatible refusal audit receipts |

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
            if error is CancellationError || error is ProcessRunCancellation {
                let produced = (error as? ProcessRunCancellation).map { stopped in
                    MacControlResult(ok: false, action: action, output: .object([
                        "stdout": .string(stopped.result.stdout), "stderr": .string(stopped.result.stderr),
                        "stdout_truncated": .bool(stopped.result.stdoutTruncated),
                        "stderr_truncated": .bool(stopped.result.stderrTruncated),
                        "exit_code": .int(Int64(stopped.result.exitCode)),
                        "cancelled": .bool(true), "timed_out": .bool(stopped.result.timedOut)
                    ]), error: "process_cancelled", durationMs: 0)
                }
                if trigger == .deadline {
                    let record = try await operationStore.transition(
                        operationId: operationId,
                        to: .timedOut,
                        verification: .failed,
                        expectedNextEvidence: nil,
                        outcomeCode: "deadline_exceeded_after_stop"
                    )
                    return produced.map { Self.attachingOperation($0, record: record) }
                        ?? Self.timeoutResult(action: action, record: record)
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
                return produced.map { Self.attachingOperation($0, record: record) }
                    ?? Self.cancelledResult(action: action, record: record)
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

    // MARK: blocked-receipt audit append

    /// Preserve the audit format's legacy method names for renamed actions. Actions without a historical alias keep their dispatch name.
    private static func daemonMethodName(forAction action: String, body: [String: JSONValue]) -> String {
        switch action {
        case "applescript":   return "run_applescript"
        case "jxa":           return "run_jxa"
        case "shortcut",
             "shortcut/run":  return "run_shortcut"
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

    /// System dispatch records the concrete operation; unknown actions retain the generic system label.
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

    /// Legacy receipt metadata only: an absent list records shell, an empty list none.
    private static func receiptApprovalRequired(forCategory category: String, policy: MacControlPolicy) -> Bool {
        guard let list = policy.approvalRequiredFor else {
            return category == "shell"
        }
        return list.contains(category)
    }

    /// Append a refusal under the shared cross-process lock. A failed audit must not turn a refused action into an executed one. Local JSONL evidence: off-disk backup only; no local backup/export/phone copy; PrivacyMap: mac_control_audit.
    /// Preserve the legacy receipt's insertion order, Python JSON separators, and UTC microsecond timestamp. Do not add fields or pass through the ordinary sorted-key JSON serializer: consumers retain these exact bytes.
    func emitBlockedAudit(
        action: String,
        category: String,
        reason: String,
        trigger: String,
        policy: MacControlPolicy,
        body: [String: JSONValue]
    ) async {
        guard let path = auditAppendPath else { return }
        // EXACT make_receipt(...) insertion order. Emitting via serializeOrderedObjectPython preserves this order (no sort) and uses Python's default compact separators `(', ', ': ')`.
        let orderedPairs: [(String, JSONValue)] = [
            // Receipt UUIDs are lowercase.
            ("id", .string(UUID().uuidString.lowercased())),
            ("method", .string(Self.daemonMethodName(forAction: action, body: body))),
            ("category", .string(category)),
            // make_receipt sets args_hash="sha256:none" when args is None; _blocked_receipt passes no args, so this matches.
            ("args_hash", .string("sha256:none")),
            ("trigger", .string(trigger)),
            ("trigger_source", .string(trigger)),
            ("approval_required", .bool(Self.receiptApprovalRequired(forCategory: category, policy: policy))),
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
            try await SwiftNativePersistenceCore.withFileLock(path) {
                try await SwiftNativePersistenceCore.appendAuditLineRaw(line, to: path)
                // Retention shares the append lock and preserves the raw audit format.
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

    /// Preserve the saved audit format: UTC +00:00, six fractional digits except at whole seconds, where the fraction is omitted. Both calendar components and microseconds derive from one floored epoch value.
    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
    }
}

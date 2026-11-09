import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
import ToolRegistry
import Synchronization
import ChatToolParsing
// Blueprint: | `ToolLoopSupport.swift` | `ToolLoopTraceObservation`; `ToolDispatchDeadline`; Retained loop evidence and response deadlines |

/// Retains loop evidence across a throw without changing the public error carriers.
final class ToolLoopTraceObservation: Sendable {
    private let state = Mutex<(payload: [String: JSONValue], dispatches: [TurnEngineResult.ToolDispatchRecord], prose: String)>(([:], [], ""))

    func record(_ counters: TurnEngineResult.LoopCounters, dispatches: [TurnEngineResult.ToolDispatchRecord], reply: String) {
        state.withLock {
            $0.payload = counters.tracePayload
            $0.payload.merge(Self.toolCounts(dispatches), uniquingKeysWith: { _, new in new })
            $0.dispatches = dispatches
            $0.prose = reply
        }
    }

    var partialReply: String { state.withLock { $0.prose } }
    var toolDispatches: [TurnEngineResult.ToolDispatchRecord] { state.withLock { $0.dispatches } }
    var tracePayload: [String: JSONValue] { state.withLock { $0.payload } }

    static func toolCounts(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> [String: JSONValue] {
        let attempts = dispatches.filter {
            let reply = ToolResult($0.result)
            return !ChatToolOutcome.neverRan(reply.payload)
                && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
        }
        return [
            "toolAttemptCount": .int(Int64(attempts.count)),
            "failedToolAttemptCount": .int(Int64(dispatches.filter { isFailedAttempt($0.result) }.count)),
            "skippedToolSlotCount": .int(Int64(dispatches.filter {
                ChatToolOutcome.neverRan($0.result)
            }.count)),
        ]
    }

    static func isFailedAttempt(_ output: JSONValue) -> Bool {
        let reply = ToolResult(output)
        return !ChatToolOutcome.neverRan(reply.payload) && [.failed, .refused, .timeout].contains(reply.outcome)
            && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
    }
}
extension TurnEngineResult.LoopCounters {
    var tracePayload: [String: JSONValue] {
        [
            "providerAttemptCount": .int(Int64(providerAttemptCount)),
            "failedProviderAttemptCount": .int(Int64(failedProviderAttemptCount)),
            "providerRoundCount": .int(Int64(providerRoundCount)),
            "toolRoundCount": .int(Int64(toolRoundCount)),
            "roundsAfterToolFailureCount": .int(Int64(roundsAfterToolFailureCount)),
            "protocolViolationRoundCount": .int(Int64(protocolViolationRoundCount)),
            "emptyReplyRoundCount": .int(Int64(emptyReplyRoundCount)),
        ]
    }
}

// MARK: - Per-tool-dispatch deadline
// Bound only the response wait; the tool retains receipt and checkpoint settlement. Expiry never cancels a write.
// Stop requests cancellation, but neither Stop nor timeout proves the effect stopped.
public enum ToolDispatchDeadline {
    /// Nonpositive or nonfinite override values explicitly disable the universal response backstop.
    static let envVar = "NATIVE_AGENT_TOOL_DISPATCH_TIMEOUT_SECONDS"

    /// Set unattended backstop beyond the longest 1-hour self-bounded tool so valid work retains its requested window.
    static let defaultUnattendedSeconds: TimeInterval = 3900
    /// Interactive calls get a 15-minute backstop; explicit tool timeouts retain their requested window plus cleanup margin up to 1 hour.
    static let defaultInteractiveSeconds: TimeInterval = 900
    static let cleanupMarginSeconds: TimeInterval = 30

    /// Unattended surfaces need a backstop because nobody is watching to recover a wedged wait.
    static func isUnattended(surface: String) -> Bool {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "autonomy", "background",
             "worker", "workers", "training":
            return true
        case let s where WorkshopSurfaceVocabulary.isWorkshopSurface(s):
            return true
        default:
            return false
        }
    }

    /// Add 30 seconds for teardown without shortening explicit work. Only observation takes the shorter Mac ceiling;
    /// actions keep the general backstop so earlier steps cannot be cut off by a later observation timeout.
    static func timeoutNanos(
        toolName: String,
        input: [String: JSONValue],
        surface: String
    ) -> UInt64 {
        let raw: TimeInterval
        if let env = ProcessInfo.processInfo.environment[envVar],
           let parsed = TimeInterval(env.trimmingCharacters(in: .whitespaces)) {
            raw = parsed
        } else if case .int(let requested)? = input["timeout_seconds"] {
            raw = TimeInterval(max(30, min(3600, Int(requested)))) + cleanupMarginSeconds
        } else if toolName == "phone_request" {
            let seconds: Int64
            if case .int(let value)? = input["wait_seconds"] { seconds = value } else { seconds = 60 }
            raw = TimeInterval(max(1, min(120, seconds))) + cleanupMarginSeconds
        } else if toolName == "image_generate" {
            raw = 600 + cleanupMarginSeconds
        } else if ["screen", "menu", "mac_look", "mac_view"].contains(toolName) {
            raw = 180
        } else if toolName == "wait", input["agent"] == nil {
            // The screen wait itself caps at 60s; leave time for its final look.
            raw = 120
        } else {
            raw = isUnattended(surface: surface)
                ? defaultUnattendedSeconds
                : defaultInteractiveSeconds
        }
        guard raw.isFinite, raw > 0 else { return 0 }
        let capped = min(raw, 24 * 3600)
        return UInt64(capped * 1_000_000_000)
    }

    /// A wait expiry is not the tool's terminal outcome.
    static func timeoutError(tool: String, seconds: TimeInterval) -> ToolFailureError {
        let label = seconds >= 1 ? "\(Int(seconds))s" : "\(Int(seconds * 1000))ms"
        return ToolFailureError("""
            The wait for tool '\(tool)' exceeded \(label). Its original work continues to its own limit; effects are \
            unknown until its receipt arrives.
            """,
            effects: .unknown, owner: tool, code: "tool_dispatch_wait_expired", status: .timeout,
            instruction: """
                Read this turn's tool.dispatch.settled receipt and inspect the affected state before proposing another action. A missing receipt is \
                an unknown outcome, never permission to repeat the write.
                """,
            recovery: .reconcile)
    }
}

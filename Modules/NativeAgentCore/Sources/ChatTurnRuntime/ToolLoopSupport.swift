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

// MARK: - Provider-facing result ceiling

/// Page oversized live results into whole JSON sections so one response cannot consume the remaining window.
/// Keep ordinary receipt projections and recover existing output before repeating any operation.
enum ProviderToolResultPage {
    static let defaultMaxUTF8Bytes = 48_000

    static func project(
        toolName: String,
        content: String,
        sessionId: String? = nil,
        turnId: String? = nil,
        originalResultClass: ChatToolOutcome.ExactResultClass? = nil,
        appDoor: Bool = false
    ) async -> String {
        let limit = defaultMaxUTF8Bytes
        guard content.utf8.count > limit else { return content }
        do {
        let parsed = try? JSONValue.parse(Data(content.utf8))
        let originalResultClass = originalResultClass ?? (content.utf8.count <= ProviderToolResultRecoveryStore.maxEntryBytes
            ? parsed.map({ ToolResult($0).outcome }) ?? .unknown : .unknown)
        let recovery = try await ProviderToolResultRecoveryStore.shared.store(
            content: content,
            parsed: parsed,
            toolName: toolName,
            sessionId: sessionId,
            turnId: turnId,
            originalResultClass: originalResultClass,
            sectionBudget: min(ToolResultSections.pageBudget, limit - 3_000)
        )
        let budget = min(ToolResultSections.pageBudget, limit - 3_000)
        var fields: [String: JSONValue]
        if let recovery, case .object(let page) = await ProviderToolResultRecoveryStore.shared.page(
            handle: recovery.handle, page: 0, sessionId: sessionId, turnId: turnId,
            query: ""
        ) {
            fields = page
            fields["recovery_tool"] = .string(appDoor ? "app result.page" : "tool_result_page")
            if appDoor, case .string(let detail)? = fields["detail"] {
                fields["detail"] = .string(ToolNameAliases.foldedProse(detail))
            }
            fields["retained_bytes"] = .int(Int64(recovery.bytes))
        } else {
            fields = ["sections": .array(ToolResultSections.pages(sections: try ToolResultSections.projection(content: content, value: parsed,
                budget: budget), query: "", budget: budget)[0]),
                "detail": .string("""
                    Only the displayed whole sections are included. The original could not be retained. Inspect an existing saved result; missing \
                    output does not establish failure.
                    """)]
        }
        fields["provider_projection"] = .string("bounded_tool_result")
        fields["tool"] = .string(appDoor ? ToolNameAliases.appAction(toolName) ?? toolName : toolName)
        fields["original_result_class"] = .string(originalResultClass.rawValue)
        fields["verification_scope"] = .string("tool_response_not_external_outcome")
        fields["original_characters"] = .int(Int64(content.count))
        fields["original_bytes"] = .int(Int64(content.utf8.count))
        fields["full_result_retained"] = .bool(recovery != nil)
        fields["retention_reason"] = .string(recovery == nil ? "retention_unavailable" : "response_exceeds_inline_limit")
        // Keep exact live home controls outside paged reading evidence; never reconstruct or replay controls from retained content.
        if toolName == "app", case .object(var frame)? = parsed {
            fields["version"] = frame["version"]
            // Put a home-item send's receipt above the room view so its own outcome remains visible.
            if case .object(let view)? = frame["view"] { frame.merge(view) { top, _ in top } }
            let keys: Set<String> = ["status", "workspace", "path", "actions", "windows", "places", "desktop"]
            let navigation = JSONValue.object(frame.filter { keys.contains($0.key) })
            var candidate = fields
            candidate["navigation"] = navigation
            if let encoded = try? JSONValue.object(candidate).serialize(pretty: false), encoded.utf8.count <= limit {
                fields = candidate
            }
        }
        return try JSONValue.object(fields).serialize(pretty: false)
        } catch {
            return """
                Tool result projection is unavailable because its values could not be encoded: \(error.localizedDescription). This does not establish \
                whether the tool's effects occurred. Inspect the saved result and repair its producing owner before repeating an action.
                """
        }
    }
}

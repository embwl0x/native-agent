import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
import ToolRegistry
import Synchronization
// Blueprint: | `ToolLoopSupport.swift` | `ToolLoopTraceObservation` retains prose and dispatch evidence across every loop throw and owns failed-attempt classification; legacy failed-slot counting stays separate; `ToolDispatchDeadline` |

/// Retains loop evidence across a throw without changing the public error carriers.
final class ToolLoopTraceObservation: Sendable {
    @TaskLocal static var current: ToolLoopTraceObservation?
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
            !ChatToolOutcome.neverRan($0.result)
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
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
        !ChatToolOutcome.neverRan(output) && [.failed, .refused, .timeout].contains(ChatToolOutcome.exactResultClass(output))
            && !ChatToolOutcome.isWaitingOnPerson(output)
    }
}

extension TurnEngineResult.LoopCounters {
    var tracePayload: [String: JSONValue] {
        [
            "providerAttemptCount": .int(Int64(providerAttemptCount)),
            "failedProviderAttemptCount": .int(Int64(failedProviderAttemptCount)),
            "providerRoundCount": .int(Int64(providerRoundCount)),
            "contextOverflowRecoveryCount": .int(Int64(contextOverflowRecoveryCount)),
            "toolRoundCount": .int(Int64(toolRoundCount)),
            "roundsAfterToolFailureCount": .int(Int64(roundsAfterToolFailureCount)),
            "protocolViolationRoundCount": .int(Int64(protocolViolationRoundCount)),
            "emptyReplyRoundCount": .int(Int64(emptyReplyRoundCount)),
        ]
    }
}

// MARK: - Per-tool-dispatch deadline
//
// runSingleDispatch races each call against a deadline and returns ToolDispatchTimedOut as that slot's error.
// Interactive and unattended calls have backstops; explicit timeout_seconds retains its window plus cleanup margin.
// Structured concurrency cannot preempt a non-cooperative synchronous child and awaits it at scope exit.
public enum ToolDispatchDeadline {
    /// Env override for the universal backstop, in seconds. <=0 / non-finite
    /// disables it on every surface.
    static let envVar = "NATIVE_AGENT_TOOL_DISPATCH_TIMEOUT_SECONDS"

    /// Default backstop for an unattended surface. Above the longest
    /// self-bounding tool (timeout_seconds <=3600s) so it never clips legit
    /// work; only an unbounded wedge ever reaches it.
    static let defaultUnattendedSeconds: TimeInterval = 3900
    /// Interactive calls should never hang forever either. Fifteen minutes is
    /// above normal connector/MCP work; tools that expose timeout_seconds keep
    /// their requested duration plus a cleanup margin, up to their 1h cap.
    static let defaultInteractiveSeconds: TimeInterval = 900
    static let cleanupMarginSeconds: TimeInterval = 30

    /// Surfaces with no human watching the turn — a hung tool there freezes
    /// work nobody can recover without an app restart. Mirrors the
    /// machine-driven surfaces, including training.
    static func isUnattended(surface: String) -> Bool {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "autonomy", "background",
             "swarm", "swarms", "worker", "workers", "training":
            return true
        case let s where WorkshopSurfaceVocabulary.isWorkshopGateSurface(s):
            return true
        default:
            return false
        }
    }

    /// Per-dispatch deadline. Explicit tool timeouts are honored with a 30s
    /// teardown margin, so this backstop cannot shorten requested long work.
    /// Mac observation has a shorter ceiling; actions keep the general backstop so
    /// a valid multi-step batch is never cut off after earlier steps acted.
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
        } else if toolName == "invoke_codex" || toolName == "image_generate" {
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

    /// Thrown by the deadline task when a dispatch exceeds its backstop.
    /// CustomStringConvertible so the existing
    /// `String(describing:)` catch yields a clean, model-readable message.
    struct ToolDispatchTimedOut: Error, CustomStringConvertible {
        let tool: String
        let seconds: TimeInterval
        var description: String {
            // ms/s label so a sub-second deadline doesn't render as "0s"
            // (loop #1's diagnostic lesson).
            let label = seconds >= 1 ? "\(Int(seconds))s" : "\(Int(seconds * 1000))ms"
            return "tool '\(tool)' exceeded the \(label) dispatch deadline; the outcome is uncertain and effects may already have occurred. Inspect the original receipt and current state before retrying. After reconciliation, any authorized new attempt can use narrower work, an explicit timeout_seconds value, or the asynchronous message tool"
        }
    }
}

// MARK: - Tool-result stub
//
// The stub `IntraTurnContextCompaction` puts in place of an older tool-result
// body under window pressure. Historical tool receipts are bounded; a temporary
// output handle belongs to its turn and never promises full source retention.
enum IntraTurnToolResultClearing {
    /// Preserved head length; independent of SessionHistory's cross-turn head-and-tail projection budget.
    static let headLength = 180

    /// Prefix of OUR stub's terminal marker line.
    static let clearedMarkerPrefix = "[cleared: full result was "

    /// Suffix of OUR stub's terminal marker line.
    static let clearedMarkerSuffix = " chars; recover the existing output from its receipt or saved result; do not repeat mutations or external sends merely to recover output]"

    /// A body is already stubbed only if its final line is exactly the marker prefix, decimal character count and suffix.
    static func isAlreadyStubbed(_ content: String) -> Bool {
        guard content.hasSuffix(clearedMarkerSuffix) else { return false }
        let lastLine = content.split(separator: "\n", omittingEmptySubsequences: false).last
            ?? Substring(content)
        guard lastLine.hasPrefix(clearedMarkerPrefix) else { return false }
        let count = lastLine
            .dropFirst(clearedMarkerPrefix.count)
            .dropLast(clearedMarkerSuffix.count)
        return !count.isEmpty && count.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Stubbed form of a tool-result body, or nil when the body should be
    /// kept as-is (already stubbed, or so short the stub would not shrink
    /// it — clearing must never GROW the payload). Re-stubbing a stub would
    /// corrupt the original-length record, hence the sentinel guard.
    static func stub(_ content: String) -> String? {
        guard !isAlreadyStubbed(content) else { return nil }
        let head = String(content.prefix(headLength))
        let stubbed = "\(head)\n\(clearedMarkerPrefix)\(content.count)\(clearedMarkerSuffix)"
        guard stubbed.count < content.count else { return nil }
        return stubbed
    }
}

// MARK: - Provider-facing result ceiling

/// Keeps one unexpectedly large tool response from consuming the rest of a
/// model window. Dispatch records and persisted receipts retain their normal
/// bounded projections; only the live provider block is replaced with a
/// valid JSON page containing whole sections. Recover the existing
/// output before deciding whether another operation is needed.
enum ProviderToolResultPage {
    static let defaultMaxUTF8Bytes = 48_000
    static let compactMaxUTF8Bytes = 12_000

    static func maxUTF8Bytes(for toolName: String) -> Int {
        if toolName == "invoke_codex" {
            return compactMaxUTF8Bytes
        }
        return defaultMaxUTF8Bytes
    }

    static func project(
        toolName: String,
        content: String,
        sessionId: String? = nil,
        turnId: String? = nil,
        originalResultClass: ChatToolOutcome.ExactResultClass? = nil,
        appDoor: Bool = false
    ) async -> String {
        let limit = maxUTF8Bytes(for: toolName)
        guard content.utf8.count > limit else { return content }

        let parsed = try? JSONValue.parse(Data(content.utf8))
        let originalResultClass = originalResultClass ?? (content.utf8.count <= ProviderToolResultRecoveryStore.maxEntryBytes
            ? parsed.map(ChatToolOutcome.exactResultClass) ?? .unknown : .unknown)
        let recovery = await ProviderToolResultRecoveryStore.shared.store(
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
            // Through the door the page is app's result.page.
            fields["recovery_tool"] = .string(appDoor ? "app result.page" : "tool_result_page")
            if appDoor, case .string(let detail)? = fields["detail"] {
                fields["detail"] = .string(ToolNameAliases.foldedProse(detail))
            }
            fields["retained_bytes"] = .int(Int64(recovery.bytes))
        } else {
            fields = ["sections": .array(ToolResultSections.pages(sections: ToolResultSections.projection(content: content, value: parsed, budget: budget), query: "", budget: budget)[0]),
                "detail": .string("Only the displayed whole sections are included. The original could not be retained. Inspect an existing saved result; missing output does not establish failure.")]
        }
        fields["provider_projection"] = .string("bounded_tool_result")
        fields["tool"] = .string(appDoor ? ToolNameAliases.appAction(toolName) ?? toolName : toolName)
        fields["original_result_class"] = .string(originalResultClass.rawValue)
        fields["verification_scope"] = .string("tool_response_not_external_outcome")
        fields["original_characters"] = .int(Int64(content.count))
        fields["original_bytes"] = .int(Int64(content.utf8.count))
        fields["full_result_retained"] = .bool(recovery != nil)
        fields["retention_reason"] = .string(recovery == nil ? "retention_unavailable" : "response_exceeds_inline_limit")
        // Home's controls must remain usable even when a page's reading
        // evidence is paged. Preserve the exact live controls, never reconstruct
        // or replay them from retained content. The full result remains paged.
        if toolName == "app", case .object(var frame)? = parsed {
            fields["version"] = frame["version"]
            // A home-item send puts its receipt on top and the room under view.
            if case .object(let view)? = frame["view"] { frame.merge(view) { top, _ in top } }
            let keys: Set<String> = ["status", "workspace", "path", "actions", "windows", "places", "desktop"]
            let navigation = JSONValue.object(frame.filter { keys.contains($0.key) })
            var candidate = fields
            candidate["navigation"] = navigation
            if let encoded = try? JSONValue.object(candidate).serialize(pretty: false), encoded.utf8.count <= limit {
                fields = candidate
            }
        }
        return (try? JSONValue.object(fields).serialize(pretty: false)) ?? "{}"
    }
}

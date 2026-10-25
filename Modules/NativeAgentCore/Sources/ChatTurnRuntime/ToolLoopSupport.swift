import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
import ToolRegistry
// Blueprint: | `ToolLoopSupport.swift` | `ToolLoopTraceObservation` retains prose and dispatch evidence across every loop throw and owns failed-attempt classification; legacy failed-slot counting stays separate; `ToolDispatchDeadline` |

/// Retains loop evidence across a throw without changing the public error carriers.
final class ToolLoopTraceObservation: @unchecked Sendable {
    @TaskLocal static var current: ToolLoopTraceObservation?
    private let lock = NSLock()
    private var payload: [String: JSONValue] = [:]
    private var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
    private var prose = ""

    func record(_ counters: TurnEngineResult.LoopCounters, dispatches: [TurnEngineResult.ToolDispatchRecord], reply: String) {
        lock.lock()
        defer { lock.unlock() }
        payload = counters.tracePayload
        payload.merge(Self.toolCounts(dispatches), uniquingKeysWith: { _, new in new })
        self.dispatches = dispatches
        prose = reply
    }

    var partialReply: String {
        lock.lock()
        defer { lock.unlock() }
        return prose
    }

    var toolDispatches: [TurnEngineResult.ToolDispatchRecord] {
        lock.lock()
        defer { lock.unlock() }
        return dispatches
    }

    var tracePayload: [String: JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    static func toolCounts(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> [String: JSONValue] {
        let attempts = dispatches.filter {
            !ChatToolOutcome.neverRan($0.result)
                && (!wasStopped($0.result) || ChatToolOutcome.effectsUnknown($0.result))
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
        }
        return [
            "toolAttemptCount": .int(Int64(attempts.count)),
            "failedToolAttemptCount": .int(Int64(dispatches.filter { isFailedAttempt($0.result) }.count)),
            "skippedToolSlotCount": .int(Int64(dispatches.filter {
                ChatToolOutcome.neverRan($0.result)
                    || (wasStopped($0.result) && !ChatToolOutcome.effectsUnknown($0.result))
            }.count)),
        ]
    }

    static func isFailedAttempt(_ output: JSONValue) -> Bool {
        !ChatToolOutcome.neverRan(output) && !ChatToolOutcome.outputLooksSuccessful(output)
            && !wasStopped(output) && !ChatToolOutcome.wasCancelled(output)
            && !ChatToolOutcome.isWaitingOnPerson(output)
    }

    /// The loop's Stop envelopes include an error sentence, which outranks status in the shared classifier.
    static func wasStopped(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        return object["cancelled"] == .bool(true) && object["status"] == .string("cancelled")
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

// MARK: - Per-tool-dispatch deadline (Trust loop #3, 2026-06-15)
//
// The chat tool loop's only existing brake on a single tool call is the
// dispatch boundary. The LLM *stream* is guarded by ProviderStreamGuard
// (idle 90s / wall 600s) but a single `tools.dispatch(...)` has NO timeout —
// so a wedged tool (dead network, an MCP server that never answers, a stuck
// subprocess) freezes that one dispatch forever. On any surface the whole
// turn then hangs until the app restarts. This is
// the same freeze class loop #1 fixed for the execution *step* path, on the
// OTHER execution path: the chat tool loop driving an autonomous turn.
//
// runSingleDispatch races each dispatch against a
// hard deadline; on expiry the deadline task throws ToolDispatchTimedOut,
// which runSingleDispatch's existing catch turns into the slot's
// {"error": ...} result — so the loop continues exactly as it does for any
// tool error, and the model sees the timeout as recoverable feedback.
//
// INTERACTIVE surfaces (chat / telegram / ios / mobile / …) use a generous
// finite backstop too. A human being present does not make a frozen turn
// recoverable. Explicit timeout_seconds requests retain their requested window
// plus cleanup margin, so the watchdog prevents unbounded wedges without
// shortening intentionally long work.
//
// The unattended default (3900s) sits ABOVE the longest self-bounding tool
// (an explicit timeout_seconds clamps to <=3600s),
// so it NEVER clips a legitimately long tool — it only ever fires for a
// genuinely UNBOUNDED wedge (shell / network / MCP with no internal timeout,
// all of which complete in seconds-to-minutes normally). It is a backstop
// against "hangs forever," not a tight per-tool SLA.
//
// RESIDUAL (identical to the execution step deadline, gpt-5.5-concurred): a
// NON-cooperative sync wedge that never suspends / swallows CancellationError
// can't be preempted — structured concurrency awaits the child at scope exit,
// so the group can't return until that child does. Every realistic I/O hang
// (async network / subprocess) IS cooperative and IS bounded here; a
// guaranteed kill of a sync wedge needs a process/tool-layer boundary.
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
        // Wave 5b: Workshop spellings via `WorkshopSurfaceVocabulary`
        // (same three strings as the open-coded list this replaces).
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

// MARK: - Tool-result stub (U1 step 5, 2026-06-10)
//
// The stub `IntraTurnContextCompaction` puts in place of an older tool-result
// body under window pressure: a 180-char head plus a marker telling the model
// to recover the existing output without repeating effects. Disk persistence,
// transcripts and traces keep full bodies — session history is written from
// TurnEngineResult.toolDispatches + progress events, never from the in-flight
// conversation.
enum IntraTurnToolResultClearing {
    /// Head of the original body preserved in the stub. Sized in the same
    /// ballpark as the cross-turn projection in SessionHistory
    /// (`toolResultProjection`, which since sweep R4 keeps head+tail rather
    /// than a 180-char head); the two budgets are independent.
    static let headLength = 180

    /// Prefix of OUR stub's terminal marker line.
    static let clearedMarkerPrefix = "[cleared: full result was "

    /// Suffix of OUR stub's terminal marker line.
    static let clearedMarkerSuffix = " chars; recover the existing output from its receipt or saved result; do not repeat mutations or external sends merely to recover output]"

    /// Idempotence sentinel (tightened 2026-06-10 review fix): a body counts
    /// as already-stubbed only when it ENDS with our exact terminal marker
    /// line — prefix + decimal char count + suffix. The old
    /// substring-anywhere check permanently exempted any ORIGINAL tool
    /// result that merely mentioned the marker phrase from clearing.
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
enum ProviderToolResultProjection {
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

        let recovery = await ProviderToolResultRecoveryStore.shared.store(
            content: content,
            toolName: toolName,
            sessionId: sessionId,
            turnId: turnId,
            originalResultClass: originalResultClass,
            sectionBudget: min(ToolResultSections.pageBudget, limit - 3_000)
        )
        let originalResultClass = recovery?.resultClass
            ?? originalResultClass ?? ProviderToolResultRecoveryStore.resultClass(content: content)

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
            fields = ["sections": .array(ToolResultSections.pages(content: content, budget: budget)[0]),
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
        if toolName == "app", let data = content.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(var frame) = value {
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

import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
import ToolRegistry

/// Retains loop evidence across a throw without changing the public error carriers.
final class ToolLoopTraceObservation: @unchecked Sendable {
    @TaskLocal static var current: ToolLoopTraceObservation?
    private let lock = NSLock()
    private var payload: [String: JSONValue] = [:]
    private var dispatches: [TurnEngineResult.ToolDispatchRecord] = []

    func record(_ counters: TurnEngineResult.LoopCounters, dispatches: [TurnEngineResult.ToolDispatchRecord]) {
        lock.lock()
        defer { lock.unlock() }
        payload = counters.tracePayload
        payload.merge(Self.toolCounts(dispatches), uniquingKeysWith: { _, new in new })
        self.dispatches = dispatches
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
            "failedToolAttemptCount": .int(Int64(attempts.filter {
                !ChatToolOutcome.outputLooksSuccessful($0.result)
                    && !wasStopped($0.result) && !ChatToolOutcome.wasCancelled($0.result)
            }.count)),
            "skippedToolSlotCount": .int(Int64(dispatches.filter {
                ChatToolOutcome.neverRan($0.result)
                    || (wasStopped($0.result) && !ChatToolOutcome.effectsUnknown($0.result))
            }.count)),
        ]
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
            "providerRecoveryCount": .int(Int64(providerRecoveryCount)),
            "providerReplayCount": .int(Int64(providerReplayCount)),
            "providerContinuationCount": .int(Int64(providerContinuationCount)),
            "contextOverflowRecoveryCount": .int(Int64(contextOverflowRecoveryCount)),
            "toolRoundCount": .int(Int64(toolRoundCount)),
            "roundsAfterToolFailureCount": .int(Int64(roundsAfterToolFailureCount)),
            "protocolViolationRoundCount": .int(Int64(protocolViolationRoundCount)),
            "emptyReplyRoundCount": .int(Int64(emptyReplyRoundCount)),
            "unfulfilledPromiseRoundCount": .int(Int64(unfulfilledPromiseRoundCount)),
        ]
    }
}

// MARK: - Error extension

extension TurnEngineError {
    /// Carrier for max-iteration overflow. We can't add a new case to the
    /// existing enum without touching its declaration, so the loop throws
    /// this nested type instead.
    public struct ToolLoopExhausted: Error, LocalizedError {
        public let iterations: Int
        public init(iterations: Int) { self.iterations = iterations }
        public var errorDescription: String? {
            "tool loop exhausted after \(iterations) iterations without a final reply"
        }
    }
}

// MARK: - Tool-loop-exhausted fallback reply

/// The single wording for a tool loop that stopped without a final reply.
/// The tool loop builds its best-effort fallback reply from this so the
/// phrasing can't drift again. Execution counters stay in diagnostic receipts.
enum ToolLoopExhaustion {
    static func fallbackReply(
        iterationLimit: Int,
        dispatchCount: Int,
        providerRounds: Int,
        wallClockElapsedSeconds: Int? = nil
    ) -> String {
        "I stopped before I could finish my reply."
    }

    /// A turn that COMPLETED with no text at all. An assistant row is never
    /// blank: an empty final reply used to persist an empty bubble under the
    /// receipts — the "Looked something up · 8 of 12 failed" card with nothing
    /// said beside it. Say plainly that no answer came back.
    static func emptyReply(dispatchCount: Int, providerRounds: Int) -> String {
        "I did not receive an answer to share."
    }
}

// MARK: - Post-tool-effect provider failures (whole-turn retry unsafe)

/// A provider failure thrown AFTER at least one tool dispatch in this turn
/// already produced side effects. Surface-level retry ladders (Telegram's
/// whole-turn retry is the live one) MUST NOT replay the full turn on this
/// error: replaying re-executes the tools (messages re-send, files re-write),
/// and `suppressUserAppend` only dedupes transcript rows, not tool effects
/// (gpt-5.5 fix round 2026-07-18, HIGH). ProviderFailureWrapping carries the
/// cross-module replay veto; the diagnostic description retains its marker.
public struct ProviderErrorAfterToolEffects: Error, LocalizedError, CustomStringConvertible {
    public let underlying: Error
    public let dispatchCount: Int

    public static let markerPhrase = "whole-turn retry unsafe: tool effects present"

    public var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
    }
    public var description: String {
        let inner = (underlying as? LocalizedError)?.errorDescription
            ?? String(describing: underlying)
        return "provider failure after \(dispatchCount) tool dispatch(es) [\(Self.markerPhrase)]: \(inner)"
    }

    /// Completed reads also consume the turn's provider recovery budget.
    /// Retry the provider call in place; replaying the whole turn after its
    /// recovery is exhausted would repeat completed work and reset that budget.
    ///
    /// User, 2026-09-06: and except the slots a Stop reached before they ran.
    /// Those records exist only to keep the wire pairing valid; counting them
    /// by NAME made an undispatched `write_file` look like a write that had
    /// happened, and refused the turn a replay that was safe.
    ///
    /// User, 2026-09-06: a call the Stop reached AFTER it started is the other
    /// way round — it carries `effects_unknown`, and unknown effects are
    /// effects for retry safety.
    public static func effectfulCount(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> Int {
        dispatches.filter {
            // A held send or an unoffered tool never ran either.
            if ChatToolOutcome.neverRan($0.result) { return false }
            return !ChatToolOutcome.wasCancelled($0.result)
                || ChatToolOutcome.effectsUnknown($0.result)
        }.count
    }

    /// Wraps only when wrapping is meaningful: never cancellation (user stops
    /// must keep their type), never double-wraps, and never before the first
    /// EFFECTFUL tool dispatch (pre-effect failures stay retryable end-to-end).
    static func wrapping(_ error: Error, dispatchCount: Int) -> Error {
        if error is CancellationError { return error }
        if error is ProviderErrorAfterToolEffects { return error }
        guard dispatchCount > 0 else { return error }
        return ProviderErrorAfterToolEffects(underlying: error, dispatchCount: dispatchCount)
    }
}

// MARK: - Tool loop budgets

public enum ToolLoopBudget {
    public static let hardCap = 240

    public static func defaultIterations(for surface: String) -> Int {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram":
            return 180
        case "ios", "icloud", "iphone", "mobile":
            return 90
        case "swarm", "swarms", "worker", "workers":
            return 80
        // Wave 5b: Workshop spellings via `WorkshopSurfaceVocabulary`
        // (same three strings as the open-coded list this replaces).
        case "autonomy", "background":
            return 80
        // Agent-to-agent bridge lanes run delegation marathons (dispatch,
        // audit, merge, restart in one turn); 60 kept exhausting mid-pipeline
        // and dropping the tail steps (User, 2026-08-27: "that ain't enough
        // for her to do stuff"). Telegram-tier.
        case "claude-bridge", "codex-bridge":
            return 180
        case let s where WorkshopSurfaceVocabulary.isWorkshopGateSurface(s):
            return 80
        default:
            return 60
        }
    }

    public static func resolve(surface: String, requested: Int? = nil) -> Int {
        let desired = requested ?? defaultIterations(for: surface)
        return min(max(1, desired), hardCap)
    }
}

// MARK: - Whole-turn wall-clock budget (A6, 2026-08-27)

/// A monotonic, surface-scoped ceiling for the complete tool-loop turn.
///
/// This is deliberately a checkpoint budget, not a cancellation deadline. A
/// loop observes it only before starting another provider iteration, after any
/// current provider round and tool dispatch (including an explicitly requested
/// `timeout_seconds` window) has settled. Expiry therefore takes the loop's
/// existing exhausted-turn terminal path; it never manufactures a new error,
/// fallback, receipt, cancellation, or provider-failure shape.
///
/// It is also PROGRESS-AWARE (2026-08-31): a round that lands at least one
/// successful tool dispatch re-grants the surface window via `recordProgress()`,
/// capped at start + `progressCeilingSeconds`. So the ceiling a turn actually
/// feels is "how long since it last got somewhere", not "how long has it run" —
/// stuck turns still die on schedule, working turns keep working.
///
/// The `nowNanoseconds` TaskLocal is the shared injection seam for the
/// structured and text-compatible loops. Production uses uptime nanoseconds;
/// deterministic tests bind a manual monotonic clock without sleeping.
struct WholeTurnWallClockBudget: Sendable {
    typealias MonotonicClock = @Sendable () -> UInt64

    /// 600, not 180: the original 180 sat BELOW the measured p95 of User's
    /// own heavy chat turns (188s, 2026-08-27 instrument run), so the brake
    /// was clipping legitimate deep turns the day it shipped. A runaway loop
    /// still dies; a real deliberate turn cannot be touched (>3x worst case).
    static let defaultInteractiveSeconds: TimeInterval = 600
    /// 600, not 300: Telegram is the surface the agent works User's real
    /// research on REMOTELY, and it carried the shortest budget in the app —
    /// half the interactive one the same p95 evidence justified. A live
    /// multi-tool research turn was cut at 300s (2026-08-31). Same floor as
    /// interactive now; progress extension does the rest.
    static let defaultTelegramSeconds: TimeInterval = 600
    static let defaultUnattendedSeconds: TimeInterval = 3_900
    /// 6h, and it bounds the PROGRESS EXTENSION only — never a fresh window.
    /// The old ceiling was start + defaultUnattendedSeconds, which killed
    /// turns that were still landing productive rounds an hour in: a turn that
    /// re-earns its window every round is by definition not the runaway the
    /// brake exists for, so the only honest ceiling is one long enough to
    /// outlast a real work session. Surface defaults and the per-round window
    /// are untouched — a stuck turn still dies at its surface budget.
    static let progressCeilingSeconds: TimeInterval = 21_600

    @TaskLocal static var nowNanoseconds: MonotonicClock = {
        DispatchTime.now().uptimeNanoseconds
    }

    private let startedAtNanoseconds: UInt64
    /// Slides forward on `recordProgress()`, never past `ceilingNanoseconds`.
    private var deadlineNanoseconds: UInt64
    /// The surface (or override) window, re-granted by each productive round.
    private let windowNanoseconds: UInt64
    /// start + progressCeilingSeconds: an extended turn can never outlive a
    /// full work session, no matter how productive.
    private let ceilingNanoseconds: UInt64
    private let clock: MonotonicClock

    static func defaultSeconds(for surface: String) -> TimeInterval {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "telegram" {
            return defaultTelegramSeconds
        }
        switch normalized {
        case "autonomy", "background",
             "swarm", "swarms", "worker", "workers", "training":
            return defaultUnattendedSeconds
        case let value where WorkshopSurfaceVocabulary.isWorkshopGateSurface(value):
            // Includes canonical `workshop` plus both shipped legacy gate
            // spellings (`mission` / `missions`) through the vocabulary owner.
            return defaultUnattendedSeconds
        default:
            return defaultInteractiveSeconds
        }
    }

    static func start(surface: String, requestedSeconds: TimeInterval? = nil) -> Self {
        let clock = nowNanoseconds
        let startedAt = clock()
        // A caller-scoped override (the bridge profile's marathon budget)
        // wins over the surface default, clamped to the unattended ceiling.
        let seconds = min(requestedSeconds ?? defaultSeconds(for: surface), defaultUnattendedSeconds)
        let duration = UInt64(seconds * 1_000_000_000)
        let deadline = Self.offset(startedAt, by: duration)
        return Self(
            startedAtNanoseconds: startedAt,
            deadlineNanoseconds: deadline,
            windowNanoseconds: duration,
            ceilingNanoseconds: Self.offset(
                startedAt, by: UInt64(progressCeilingSeconds * 1_000_000_000)
            ),
            clock: clock
        )
    }

    private static func offset(_ base: UInt64, by duration: UInt64) -> UInt64 {
        base > UInt64.max - duration ? UInt64.max : base + duration
    }

    /// A turn that is GETTING SOMEWHERE re-earns its window: at least one tool
    /// dispatch in the round just finished came back a real result, so the
    /// deadline slides to now + the surface budget. The brake is for turns that
    /// spin, not for turns that take a while — a real research turn on Telegram
    /// was dying at the floor while it was still producing (2026-08-31).
    ///
    /// Two invariants keep this from becoming "no budget at all": the deadline
    /// only ever moves FORWARD, and it is hard-capped at start + the unattended
    /// window, so a productive interactive turn can still never outlive a
    /// background one. Surfaces already at that ceiling extend by zero.
    mutating func recordProgress() {
        let extended = Self.offset(clock(), by: windowNanoseconds)
        deadlineNanoseconds = min(max(deadlineNanoseconds, extended), ceilingNanoseconds)
    }

    var isExhausted: Bool {
        clock() >= deadlineNanoseconds
    }

    /// Seconds left before the current deadline, floored at zero. Two readers,
    /// both added 2026-09-06: the per-call provider wall is bounded by this so
    /// one hung call cannot eat the whole turn, and the reconnect ladders
    /// refuse a Retry-After longer than what is left.
    var remainingSeconds: TimeInterval {
        let now = clock()
        guard deadlineNanoseconds > now else { return 0 }
        return TimeInterval(deadlineNanoseconds - now) / 1_000_000_000
    }

    /// Whole-turn wall time so far, on the SAME clock isExhausted reads, so
    /// the exhaustion fallback message reports the budget's own elapsed value.
    var elapsedSeconds: Int {
        Int((clock() &- startedAtNanoseconds) / 1_000_000_000)
    }
}

// MARK: - Per-tool-dispatch deadline (Trust loop #3, 2026-06-15)
//
// The chat tool loop's only existing brake on a single tool call is the
// iteration cap. The LLM *stream* is guarded by ProviderStreamGuard
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
    /// machine-driven set in `ToolLoopBudget.defaultIterations` (+ "training").
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

    /// Compatibility/readout overload when no concrete tool input is known.
    static func timeoutNanos(forSurface surface: String) -> UInt64 {
        timeoutNanos(toolName: "", input: [:], surface: surface)
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
        if toolName.hasPrefix("github_")
            || toolName == "invoke_codex" {
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
        query: String? = nil,
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

        let query = query ?? ""
        let budget = min(ToolResultSections.pageBudget, limit - 3_000)
        var fields: [String: JSONValue]
        if let recovery, case .object(let page) = await ProviderToolResultRecoveryStore.shared.page(
            handle: recovery.handle, page: 0, sessionId: sessionId, turnId: turnId,
            query: query
        ) {
            fields = page
            // Through the door the page is app's result.page.
            fields["recovery_tool"] = .string(appDoor ? "app result.page" : "tool_result_page")
            if appDoor, case .string(let detail)? = fields["detail"] {
                fields["detail"] = .string(ToolNameAliases.foldedProse(detail))
            }
            fields["retained_bytes"] = .int(Int64(recovery.bytes))
        } else {
            fields = ["sections": .array(ToolResultSections.pages(content: content, query: query, budget: budget)[0]),
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

/// Detects a provider repeatedly issuing the exact same tool batch and
/// receiving the exact same results. Changed arguments or changed output
/// always reset the streak, preserving legitimate polling, paging, retries,
/// and iterative work.
struct ToolLoopNoProgressGuard {
    enum Action: Equatable {
        case none
        /// `model` is the correction addressed to the agent; `person` is what
        /// the visible progress stream may say, and is nil whenever the only
        /// thing to say is "fix your arguments" - that is the agent's job, not
        /// the reader's (2026-09-13, first-failure pass).
        case warn(model: String, person: String?)
        /// `model` ends the loop in the conversation; `person` becomes the
        /// visible final answer, so it never asserts a cause the rounds did
        /// not establish.
        case stop(model: String, person: String)
    }

    private var previous: [TurnEngineResult.ToolDispatchRecord]?
    private var identicalRoundCount = 0
    /// 2026-09-07: the same tool failing with the same error round after round
    /// is no progress even when the provider rewords the arguments each time
    /// (78 rounds of `claude_message` denied on a bad `desk_item` never tripped
    /// the identical-batch streak because the message text drifted).
    private var previousFailure: (name: String, error: String)?
    private var sameFailureRoundCount = 0

    mutating func observe(_ records: [TurnEngineResult.ToolDispatchRecord]) -> Action {
        guard !records.isEmpty else {
            previous = nil
            identicalRoundCount = 0
            previousFailure = nil
            sameFailureRoundCount = 0
            return .none
        }
        if let failure = Self.uniformFailure(records) {
            if let previousFailure, previousFailure == failure {
                sameFailureRoundCount += 1
            } else {
                previousFailure = failure
                sameFailureRoundCount = 1
            }
            if sameFailureRoundCount == 4 {
                return .warn(
                    model: "No progress detected: \(failure.name) has failed with the same error four rounds in a row (\(failure.error)). Change the call or stop calling it; rewording the arguments does not change the outcome.",
                    // Only an evidenced standing blocker is the reader's to
                    // resolve. Everything else is the agent repairing its own
                    // call, and narrating that to the person just asks them to
                    // debug a tool they never wrote.
                    person: Self.standingBlocker(failure)
                )
            }
            if sameFailureRoundCount >= 8 {
                // Eight identical failures prove repetition, nothing else: an
                // unavailable service or a revoked permission fails exactly
                // this way with perfectly good arguments. So the visible text
                // no longer claims "the call needs different inputs".
                return .stop(
                    model: "I stopped the tool loop after eight rounds of \(failure.name) failing with the same error: \(failure.error). No tool capability was disabled. Repetition alone does not say whether the arguments or the service is at fault.",
                    person: Self.standingBlocker(failure)
                        ?? "I stopped after eight attempts that failed the same way, so I did not keep retrying into it. Everything that completed is kept - the last error was: \(failure.error)"
                )
            }
        } else {
            previousFailure = nil
            sameFailureRoundCount = 0
        }
        if let previous, Self.equal(previous, records) {
            identicalRoundCount += 1
        } else {
            previous = records
            identicalRoundCount = 1
        }

        if identicalRoundCount == 8 {
            return .warn(
                model: "No progress detected: this exact tool batch has returned the same result eight rounds in a row. Change the arguments, use a narrower query or a different tool, or answer from the results already available.",
                person: nil
            )
        }
        if identicalRoundCount >= 16 {
            return .stop(
                model: "I stopped the tool loop after sixteen identical rounds with no progress. No tool capability was disabled, and all completed tool results and receipts were preserved. Retry with narrower arguments, a different tool, or an explicit longer timeout if the work truly needs it.",
                person: "I stopped after sixteen rounds that kept returning the same thing. Everything that completed is kept."
            )
        }
        return .none
    }

    /// The evidenced blocker in ordinary language, or nil when the error is
    /// only the agent's own call to repair. Matched on the typed vocabulary the
    /// dispatchers already emit (not connected, permission, denied, expired
    /// credentials, unavailable) - never on repetition, which proves nothing
    /// about the cause.
    static func standingBlocker(_ failure: (name: String, error: String)) -> String? {
        let e = failure.error.lowercased()
        if e.contains("not_connected") || e.contains("not connected") || e.contains("reauth_required") {
            return "I could not finish that because the account it needs is not connected right now. Connect it and I will pick up where I stopped."
        }
        if e.contains("permission_denied") || e.contains("integration_permission_denied")
            || e.contains("not authorized") || e.contains("permission") {
            return "I could not finish that because the permission it needs is not granted on this Mac. Grant it and I will pick up where I stopped."
        }
        if e.contains("invalid_api_key") || e.contains("authentication_error")
            || e.contains("status 401") || e.contains("expired") {
            return "I could not finish that because the credentials it needs were rejected. Reconnect that account and I will pick up where I stopped."
        }
        if e.contains("disabled") || e.contains("unavailable") || e.contains("status 503") {
            return "I could not finish that because the service behind it is unavailable right now. Nothing that already completed was lost."
        }
        return nil
    }

    /// The round's one tool name and one failure string when every record that
    /// did NOT succeed is the same tool failing the same way; nil otherwise.
    ///
    /// Two shapes this used to be blind to, and a failing turn therefore ran
    /// the full iteration / wall-clock budget:
    ///
    /// - A MIXED batch. One working call beside four identical failures is not
    ///   progress on the four; a record that succeeded is simply not part of
    ///   the stuck shape, so it is skipped rather than disqualifying the round.
    /// - The `{"status":"failed"}` envelope. Most dispatchers on this surface
    ///   report that way and carry no `error` key at all, so the old read — a
    ///   non-empty `result["error"]` on EVERY record — saw no failure at all.
    ///   Classification is `ChatToolOutcome.exactResultClass` now, the same one
    ///   the post-turn evidence reads.
    ///
    /// Anything non-terminal in the round (pending, awaiting approval,
    /// cancelled, unknown) is not a settled failure and stops the read: those
    /// are the shapes that legitimately change between rounds.
    private static func uniformFailure(
        _ records: [TurnEngineResult.ToolDispatchRecord]
    ) -> (name: String, error: String)? {
        var seen: (name: String, error: String)?
        for record in records {
            switch ChatToolOutcome.exactResultClass(record.result) {
            case .succeeded:
                continue
            case .failed, .timeout:
                // An app call is named by its action: two actions are two tools.
                let action: String? = if record.name == "app", case .string(let id)? = record.input["action"] { id } else { nil }
                let current = (name: action.map { "app " + $0 } ?? record.name, error: failureText(record.result))
                if let seen, seen != current { return nil }
                seen = current
            case .cancelled, .unknown:
                return nil
            }
        }
        return seen
    }

    /// The failing record's own words, for the warning and the stop line —
    /// and, because the streak is keyed on this string, its identity.
    ///
    /// EVERY populated field, not the first one found. The dispatchers' generic
    /// envelope (`{"status":"failed","reason":"bots_tool_failed","detail":…}`)
    /// carries the same `reason` for unrelated breakages, so quoting one field
    /// made four different failures read as one tool failing the same way four
    /// times and ended a turn that was still getting somewhere. The specific
    /// `detail` comes before the generic `reason` and `status` so the sentence
    /// leads with what actually went wrong.
    private static func failureText(_ result: JSONValue) -> String {
        guard case .object(let object) = result else { return "failed" }
        let parts = ["error", "message", "detail", "reason", "status"].compactMap { key -> String? in
            guard case .string(let text)? = object[key] else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !parts.isEmpty else { return "failed" }
        return String(ChatSecretRedactor.redactText(parts.joined(separator: " — ")).prefix(200))
    }

    private static func equal(
        _ lhs: [TurnEngineResult.ToolDispatchRecord],
        _ rhs: [TurnEngineResult.ToolDispatchRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.name == right.name
                && left.input == right.input
                && comparableResult(left.result) == comparableResult(right.result)
        }
    }

    /// User, 2026-09-06: an approval envelope carries a FRESH `approvalId` every
    /// time one is filed, so two identical CONFIRM requests never compared equal
    /// and the streak never grew past one — the guard could not see the one loop
    /// shape it exists to stop. The id is filing bookkeeping, not the result.
    private static func comparableResult(_ result: JSONValue) -> JSONValue {
        guard ChatToolOutcome.isWaitingApproval(result),
              case .object(var object) = result else { return result }
        object["approvalId"] = nil
        return .object(object)
    }
}

/// Shared retry receipt; callers retain their distinct replay and cancellation behavior.
enum ProviderRetryTrace {
    static func emit(
        error: Error, attempt: Int, delaySeconds: TimeInterval,
        mode: String, turnRecoveries: Int, surface: String
    ) {
        TurnTraceBus.fireFromContext(
            kind: TurnLifecycleMilestone.providerRetry.rawValue,
            surface: surface,
            payload: .object([
                "attempt": .int(Int64(attempt)),
                "delaySeconds": .double(delaySeconds),
                "reason": .string(String(ProviderRecoveryPolicy.describe(error).prefix(200))),
                "mode": .string(mode),
                "turnRecoveries": .int(Int64(turnRecoveries)),
            ])
        )
    }
}

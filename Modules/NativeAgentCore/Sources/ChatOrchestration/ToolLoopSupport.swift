import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

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
/// All three loops (structured streaming, structured non-streaming, and
/// TextCompatibility) build their best-effort fallback reply from this so the
/// phrasing can't drift between them again. The message names the actual
/// rounds run and WHY the loop stopped — the old wording printed the LIMIT
/// unconditionally, so a wall-clock-cut turn (188s, ~10 rounds, 2026-08-27)
/// reported "exhausted after 180 iterations" and misled diagnosis.
enum ToolLoopExhaustion {
    static func fallbackReply(
        iterationLimit: Int,
        dispatchCount: Int,
        providerRounds: Int,
        wallClockElapsedSeconds: Int? = nil
    ) -> String {
        if let seconds = wallClockElapsedSeconds {
            return "(turn stopped by wall-clock budget after \(seconds)s / \(providerRounds) provider rounds — dispatched \(dispatchCount) tool calls, no final reply)"
        }
        return "(tool loop exhausted after \(providerRounds)/\(iterationLimit) iterations — dispatched \(dispatchCount) tool calls, no final reply)"
    }
}

/// User, 2026-09-06: the engine REFUSING to start a provider call the turn
/// cannot pay for.
///
/// The loop checks the whole-turn budget at the iteration boundary — before
/// context assembly, which itself costs real wall time — and the remainder that
/// bounds the call's wall is not sampled until the provider is about to be
/// asked. Between those two points the budget can go, and
/// `ProviderRecoveryPolicy.callWallSeconds` turns a zero remainder into the
/// 60 s FLOOR: a full minute of provider work started by a turn with nothing
/// left. `streamTurn` samples the remainder itself now and raises this instead.
///
/// It is the BUDGET ending, not a provider failure, so the text-compat loop
/// takes its exhausted exit on it — the same one the loop head takes — rather
/// than the reconnect ladder, which would replay a call there is equally no
/// time for. Typed, because that ladder classifies on the type.
struct TurnBudgetSpentBeforeProviderCall: Error, LocalizedError, CustomStringConvertible {
    var description: String {
        "turn budget spent before the provider call could start"
    }
    var errorDescription: String? { description }
}

// MARK: - Post-tool-effect provider failures (whole-turn retry unsafe)

/// A provider failure thrown AFTER at least one tool dispatch in this turn
/// already produced side effects. Surface-level retry ladders (Telegram's
/// whole-turn retry is the live one) MUST NOT replay the full turn on this
/// error: replaying re-executes the tools (messages re-send, files re-write),
/// and `suppressUserAppend` only dedupes transcript rows, not tool effects
/// (gpt-5.5 fix round 2026-07-18, HIGH). The marker phrase in the description
/// is the cross-module contract with `isRetryableChatHandlerError` — string-
/// based because that ladder matches error text, not types.
public struct ProviderErrorAfterToolEffects: Error, LocalizedError, CustomStringConvertible {
    public let underlying: Error
    public let dispatchCount: Int

    public static let markerPhrase = "whole-turn retry unsafe: tool effects present"

    public var errorDescription: String? { description }
    public var description: String {
        let inner = (underlying as? LocalizedError)?.errorDescription
            ?? String(describing: underlying)
        return "provider failure after \(dispatchCount) tool dispatch(es) [\(Self.markerPhrase)]: \(inner)"
    }

    /// Tools that read and never write. A provider failure after only these
    /// leaves nothing to re-execute, so the surface may replay the turn.
    /// User, 2026-09-04: his "do you still love me on Astra" lost its reply
    /// because chatgpt.com dropped the connection right after `inner_state`
    /// (58 ms, read-only) and the turn was refused a retry as if a message
    /// had been sent. Only names whose dispatch has no side effect belong
    /// here; when in doubt, leave a tool out.
    public static let readOnlyToolNames: Set<String> = [
        "inner_state",
        "agent_introspect",
    ]

    /// The dispatches that matter for retry safety: everything except the
    /// read-only names above.
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
            guard !readOnlyToolNames.contains($0.name) else { return false }
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
// (`invoke_claude` clamps its subprocess to <=3600s and self-terminates),
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
    /// self-bounding tool (`invoke_claude` <=3600s) so it never clips legit
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
    /// Unknown interactive I/O still gets a generous finite ceiling.
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
        } else if toolName == "invoke_claude" {
            raw = 180 + cleanupMarginSeconds
        } else if toolName == "invoke_codex" || toolName == "image_generate" {
            raw = 600 + cleanupMarginSeconds
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

// MARK: - Intra-turn tool-result clearing (U1 step 5, 2026-06-10)
//
// On tool-heavy turns the loop runs up to 60-240 iterations and the in-flight
// `conversation` array keeps every prior tool-result body FULL — so every
// iteration re-sends every prior full body to the provider (F1 live example:
// 12-18k input tokens re-paid per iteration). This sweep stubs the BODIES of
// tool results older than the keep window each time a new result is appended.
//
// CACHING CONTRACT / APPEND-CONSISTENCY:
//   * The request body is REBUILT from `conversation` on every iteration and
//     providers are stateless per request, so rewriting an older entry is
//     safe for correctness. The sweep never changes message COUNT or ORDER —
//     earlier array indices keep their positions; only the content string of
//     toolResult blocks older than the keep window shrinks.
//   * U1 item 8 UPDATE (gpt-5.5 review, 2026-06-10): there IS now a
//     per-message cache_control — the trailing-message breakpoint in the
//     Anthropic OAuth adapter caches the whole conversation prefix each
//     iteration. Rewriting older tool-result bytes changes the cached
//     prefix and torches that hit. The sweep therefore fires ONLY in
//     GrownPromptCompat mode (old wire layout, no message breakpoint);
//     in the default shape, prefix caching carries the cost instead —
//     0.1x cache-reads strictly beat clearing's uncached savings.
//     Anthropic's server-side automatic caching (U1 F1 finding) may also
//     lose opportunistic prefix hits over a rewritten region,
//     but the raw input-token saving dominates: stubbed bodies stop being
//     re-sent at all, every remaining iteration of the turn.
//   * Disk persistence / transcripts / traces are UNTOUCHED: session history
//     is written from TurnEngineResult.toolDispatches + progress events
//     (ChatOrchestrationClient.appendMessage), never from this in-flight
//     array. Both keep full bodies.
//
// CAPABILITY FLOOR (hard constraint): the model must still be able to
// reference recent results — the CURRENT iteration plus the last
// `keepFullIterations` (N=5 floor) iterations always stay full, the stub
// keeps a 180-char head (comparable in size to the cross-turn head+tail
// projection in ChatOrchestration+SessionHistory.swift `toolSummary`), and the marker tells
// the model it can re-run the tool if it needs the full body again.
enum IntraTurnToolResultClearing {
    /// Number of PRIOR loop iterations (in addition to the current one)
    /// whose tool-result bodies stay FULL in the in-flight conversation.
    /// N=5 is a FLOOR (the user's never-reduce-capabilities constraint) — lower
    /// values are not acceptable; raise only with QA-equivalence evidence.
    static let keepFullIterations = 5

    /// Head of the original body preserved in the stub. Sized in the same
    /// ballpark as the cross-turn projection in SessionHistory
    /// (`toolResultProjection`, which since sweep R4 keeps head+tail rather
    /// than a 180-char head); the two budgets are independent.
    static let headLength = 180

    /// Prefix of OUR stub's terminal marker line.
    static let clearedMarkerPrefix = "[cleared: full result was "

    /// Suffix of OUR stub's terminal marker line.
    static let clearedMarkerSuffix = " chars; re-run the tool if needed]"

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

    /// Stub tool-result bodies in every tool-result user message older than
    /// the keep window (current + keepFullIterations most recent stay full).
    /// One loop iteration appends exactly one tool-result user message, so
    /// "iterations back" == position from the end of that subsequence.
    static func sweep(_ conversation: inout [LLMMessage]) {
        let resultIndices = conversation.indices.filter { idx in
            conversation[idx].role == .user && conversation[idx].content.contains { block in
                if case .toolResult = block { return true }
                return false
            }
        }
        let keepCount = keepFullIterations + 1
        guard resultIndices.count > keepCount else { return }
        for idx in resultIndices.dropLast(keepCount) {
            let blocks = conversation[idx].content.map { block -> LLMContentBlock in
                guard case .toolResult(let toolUseId, let content, let isError) = block,
                      let stubbed = stub(content) else {
                    return block
                }
                return .toolResult(toolUseId: toolUseId, content: stubbed, isError: isError)
            }
            conversation[idx] = LLMMessage(role: .user, content: blocks)
        }
    }
}

// MARK: - Provider-facing result ceiling

/// Keeps one unexpectedly large tool response from consuming the rest of a
/// model window. Dispatch records and persisted receipts retain their normal
/// bounded projections; only the live provider block is replaced with a
/// valid JSON summary containing both the head and tail. The model can page,
/// narrow, or rerun the tool when deeper detail is genuinely needed.
enum ProviderToolResultProjection {
    static let defaultMaxUTF8Bytes = 32_000
    static let compactMaxUTF8Bytes = 12_000

    /// tool_load carries schemas_added — with the text-compat catalog pinned
    /// per turn (turn-context-iteration-cache, 2026-08-13) this result is the
    /// model's ONLY in-turn source of a just-loaded tool's parameters, so it
    /// must survive projection whole. Budget sized above the full eager
    /// catalog (~73KB) so no category load can truncate; still a ceiling.
    static let toolLoadMaxUTF8Bytes = 96_000

    static func maxUTF8Bytes(for toolName: String) -> Int {
        if toolName == "tool_load" {
            return toolLoadMaxUTF8Bytes
        }
        if toolName.hasPrefix("github_")
            || toolName == "invoke_codex"
            || toolName == "invoke_claude"
            || toolName == "tool_result_page" {
            return compactMaxUTF8Bytes
        }
        return defaultMaxUTF8Bytes
    }

    static func project(
        toolName: String,
        content: String,
        sessionId: String? = nil,
        turnId: String? = nil
    ) async -> String {
        let limit = maxUTF8Bytes(for: toolName)
        guard content.utf8.count > limit else { return content }

        let recovery = await ProviderToolResultRecoveryStore.shared.store(
            content: content,
            toolName: toolName,
            sessionId: sessionId,
            turnId: turnId
        )

        var headLimit = max(256, limit / 3)
        var tailLimit = max(128, limit / 6)
        while true {
            var fields: [String: JSONValue] = [
                "provider_projection": .string("bounded_tool_result"),
                "tool": .string(toolName),
                "original_characters": .int(Int64(content.count)),
                "original_bytes": .int(Int64(content.utf8.count)),
                "preview_head": .string(String(decoding: content.utf8.prefix(headLimit), as: UTF8.self)),
                "preview_tail": .string(String(decoding: content.utf8.suffix(tailLimit), as: UTF8.self)),
            ]
            if let recovery {
                fields["result_handle"] = .string(recovery.handle)
                fields["recovery_tool"] = .string("tool_result_page")
                fields["page_count"] = .int(Int64(recovery.pageCount))
                fields["page_bytes"] = .int(Int64(ProviderToolResultRecoveryStore.pageUTF8Bytes))
                fields["retained_bytes"] = .int(Int64(recovery.bytes))
                fields["full_result_retained"] = .bool(true)
                fields["detail"] = .string("The full redacted result is retained for this turn. Call tool_result_page with result_handle and page, or narrow/paginate the original tool.")
            } else {
                fields["full_result_retained"] = .bool(false)
                fields["detail"] = .string("The result exceeded the spill safety ceiling or this call has no turn scope. Narrow/paginate the original tool or request an artifact-backed result.")
            }
            let value = JSONValue.object(fields)
            let serialized = (try? value.serialize(pretty: false)) ?? "{}"
            if serialized.utf8.count <= limit { return serialized }
            if headLimit <= 256 && tailLimit <= 128 {
                var minimalFields: [String: JSONValue] = [
                    "provider_projection": .string("bounded_tool_result"),
                    "tool": .string(toolName),
                    "original_characters": .int(Int64(content.count)),
                    "original_bytes": .int(Int64(content.utf8.count)),
                    "full_result_retained": .bool(recovery != nil),
                ]
                if let recovery {
                    minimalFields["result_handle"] = .string(recovery.handle)
                    minimalFields["recovery_tool"] = .string("tool_result_page")
                    minimalFields["page_count"] = .int(Int64(recovery.pageCount))
                }
                return (try? JSONValue.object(minimalFields).serialize(pretty: false)) ?? "{}"
            }
            headLimit = max(256, headLimit / 2)
            tailLimit = max(128, tailLimit / 2)
        }
    }
}

/// Detects a provider repeatedly issuing the exact same tool batch and
/// receiving the exact same results. Changed arguments or changed output
/// always reset the streak, preserving legitimate polling, paging, retries,
/// and iterative work.
struct ToolLoopNoProgressGuard {
    enum Action: Equatable {
        case none
        case warn(String)
        case stop(String)
    }

    private var previous: [TurnEngineResult.ToolDispatchRecord]?
    private var identicalRoundCount = 0

    mutating func observe(_ records: [TurnEngineResult.ToolDispatchRecord]) -> Action {
        guard !records.isEmpty else {
            previous = nil
            identicalRoundCount = 0
            return .none
        }
        if let previous, Self.equal(previous, records) {
            identicalRoundCount += 1
        } else {
            previous = records
            identicalRoundCount = 1
        }

        if identicalRoundCount == 8 {
            return .warn(
                "No progress detected: this exact tool batch has returned the same result eight rounds in a row. Change the arguments, use a narrower query or a different tool, or answer from the results already available."
            )
        }
        if identicalRoundCount >= 16 {
            return .stop(
                "I stopped the tool loop after sixteen identical rounds with no progress. No tool capability was disabled, and all completed tool results and receipts were preserved. Retry with narrower arguments, a different tool, or an explicit longer timeout if the work truly needs it."
            )
        }
        return .none
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

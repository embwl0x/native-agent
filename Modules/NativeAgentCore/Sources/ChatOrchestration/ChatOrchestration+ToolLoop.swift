import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
// U1 item 8: GrownPromptCompat lever (gates the clearing sweep — see the
// IntraTurnToolResultClearing header comment).
import ProviderRouting
// U1 step 6: MacIntegrationPermissionMode for the safe-set rule 4 lookup
// (ToolPreloadHeuristics.macIntegrationGates mode comparison).
import MacIntegration
import Context

// MARK: - Phase B+: Tool-dispatch loop on top of SwiftNativeTurnEngine
//
// CARVES (intentional):
//   * Swift-native loop semantics: parse LLM response for tool markers,
//     dispatch through the injected tool client, feed compact result text back
//     into the next LLM call, and repeat until the LLM produces a final reply
//     or `maxIterations` hits.
//   * Parses TWO formats — OpenAI-style and Anthropic-style. We try each
//     parser in order and accept whichever finds calls. This keeps the loop
//     agnostic to which adapter the caller wired in.
//   * Tool dispatch failures DO NOT abort the loop — the error object is
//     appended to the prompt as the tool's "result" and the loop continues.
//     This matches daemon behavior where a tool error becomes feedback the
//     model can recover from.
//   * Persona, memory recall, model selection, and tool-list enumeration
//     happen ONCE in the initial buildTurnContext. The growing prompt is the
//     only thing that changes across iterations.
//   * This append-only loop is non-streaming. Streaming turns, session-history
//     threading, and app-level dispatch gates are handled by sibling
//     ChatOrchestrationClient/Streaming/AutonomyGate paths.
//   * `llm` / `tools` are taken as explicit parameters because the actor's
//     stored llm/tools are `private` and we are intentionally not touching
//     ChatOrchestration+TurnEngine.swift. Callers pass the same instances
//     they used to construct the engine.

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

/// The single wording for a tool loop that ran out of iterations without a
/// final reply. All three loops (structured streaming, structured
/// non-streaming, and TextCompatibility) build their best-effort fallback
/// reply from this so the phrasing can't drift between them again.
enum ToolLoopExhaustion {
    static func fallbackReply(iterationLimit: Int, dispatchCount: Int) -> String {
        "(tool loop exhausted after \(iterationLimit) iterations — dispatched \(dispatchCount) tool calls, no final reply)"
    }
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

    /// Wraps only when wrapping is meaningful: never cancellation (user stops
    /// must keep their type), never double-wraps, and never before the first
    /// tool dispatch (pre-effect failures stay retryable end-to-end).
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
            return "tool '\(tool)' exceeded the \(label) dispatch deadline and was abandoned; retry with narrower work, an explicit timeout_seconds value, or the asynchronous message tool"
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
                && left.result == right.result
        }
    }
}

/// `tool_load` mutates the session's authorized loadout during a turn. The
/// structured loops must append those schemas before the next provider call;
/// otherwise the model can see the returned schema text but cannot emit a
/// native tool call until a later user turn. Existing schemas stay in place so
/// provider aliases already present in the conversation remain stable.
private enum SameTurnToolSchemaRefresh {
    static func afterLoad(
        current: [LLMToolSchema],
        sessionId: String?,
        tools: any ToolDispatchClient,
        activeToolsStore: ActiveToolsStore
    ) async -> [LLMToolSchema] {
        let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty,
              let available = try? await tools.listAvailableToolSchemas() else {
            return current
        }

        let persisted = await activeToolsStore.load(sessionId: session).activeTools
        let active = persisted.union(LLMCallContext.turnActiveTools ?? [])
        let allowed = SwiftToolDispatcher.alwaysOnCoreNames.union(active)
        var known = Set(current.map(\.name))
        var refreshed = current
        for schema in available where !known.contains(schema.name) {
            guard schema.name.hasPrefix("mcp__") || allowed.contains(schema.name) else { continue }
            refreshed.append(schema)
            known.insert(schema.name)
        }
        return refreshed
    }

    static func wasRequested(
        calls: [ParsedToolCall],
        providerTools: ProviderToolNameMap
    ) -> Bool {
        calls.contains { providerTools.internalName(forProviderName: $0.name) == "tool_load" }
    }
}

// MARK: - Parallel dispatch of independent tool calls (U1 step 6, 2026-06-10)
//
// The OpenAI adapter requests parallel_tool_calls:true and Anthropic batches
// tool_use blocks freely — the model routinely emits 2+ calls per iteration,
// which this loop used to execute strictly one-by-one. When an iteration
// carries multiple SIDE-EFFECT-SAFE calls, they now run concurrently in a
// task group (cap: maxConcurrentPerIteration) and the results are
// reassembled in ORIGINAL INDEX ORDER, so the provider-visible wire shape —
// one assistant message with N tool_use blocks, then ONE user message with N
// tool_result blocks paired by id in the same order — is byte-identical to
// the serial path. (Pairing convention verified in both OAuth adapters:
// tool_result.tool_use_id / function_call_output.call_id echo; blocks are
// encoded in message order, so slot order == tool_use order is the contract.)
//
// SAFE-SET DERIVATION (mechanical, fail-closed — every rule is a veto;
// a tool is parallel-safe only if it survives ALL of them):
//   1. mcp__* tools → SERIAL (external server, side effects unknowable).
//   2. Full-Mac surface lists (SwiftToolDispatcher.fullMacFileToolNames /
//      SystemToolNames / AppToolNames / BuilderToolNames / RestartToolNames)
//      → SERIAL. These are the process-spawn / write-power tools (shell,
//      bash, git, apply_patch, run_tests, swift_build, swift_test, write_file,
//      grep, git_status...);
//      even the "read" git tools can touch .git/index. Referencing the
//      dispatcher constants directly keeps this list drift-proof, same
//      pattern as ToolPreloadHeuristics' builder group.
//   3. Explicit serial names: session-state mutators (tool_load/tool_unload
//      write ActiveToolsStore; agent_swarm spawns workers), the agent
//      subprocess pair (invoke_claude/invoke_codex), and the notify
//      channels — mirrors SecurityCenter.profile's explicit branches.
//   4. Mac Integration WRITE tools → SERIAL, derived from the SAME
//      (integration, mode) table the dispatch gate uses
//      (ToolPreloadHeuristics.macIntegrationGates, mode == .write).
//   5. Danger-keyword veto — the keyword classes are mirrored VERBATIM from
//      SecurityCenter.profile's classifier (shell/exec, delete/destructive,
//      write/save/create/patch/..., applescript/system-control, send/post/
//      message/reply, trade/money, secret/credential).
//   6. Positive read signal required: the name must carry one of
//      SecurityCenter's safe_read keywords (read/list/search/recall/status/
//      get) OR sit in the small audited read-only allowlist (time_now,
//      agent_introspect, web_fetch class...). No signal → SERIAL.
// Net effect: read_file, list_dir, recall_memory, search_kg, mail_search,
// x_search etc. parallelize; anything write-class, shell-class,
// Mac-Integration-write, or approval-gated (approval-gated tools are
// write/shell-class by construction in this catalog — the autonomy-gate
// dispatch wrapper continues to gate EVERY call regardless) stays serial.
//
// MIXED BATCHES: consecutive parallel-safe calls coalesce into one
// concurrent group; every unsafe call is its own serial group. Groups
// execute strictly in original order (a write at index k never overlaps
// reads at indices <k or >k), so any execution is observationally
// equivalent to the serial order for side-effect-bearing tools.
//
// ROLLBACK LEVER: set env NATIVE_AGENT_SERIAL_TOOL_DISPATCH=1 (or
// true/yes/on) to force the old strictly-serial path. Default is parallel
// ON. (`forceSerialOverride` is the task-local test hook for the same
// switch.)
//
// FAILURE ISOLATION: each concurrent child catches its own error — a
// throwing tool becomes that slot's `{"error": ...}` result exactly as the
// serial path produces, and never cancels siblings. Turn cancellation
// cancels all children via structured concurrency (task-group teardown);
// the parallel set is read-only by construction, so there are no orphan
// writes to clean up.
//
// STEP-5 INTERACTION: results are still appended as ONE user message per
// iteration, so IntraTurnToolResultClearing ages a parallel batch exactly
// like a serial one (the sweep counts tool-result MESSAGES, not blocks).
enum ParallelToolDispatch {
    /// Concurrency cap per iteration. Anything beyond this queues behind the
    /// window (completion-ordered refill).
    static let maxConcurrentPerIteration = 4

    /// Rollback lever (documented above). Checked once per process.
    static let serialFallbackEnvVar = "NATIVE_AGENT_SERIAL_TOOL_DISPATCH"

    /// Pure, injectable parser for the env flag (unit-testable without
    /// mutating process state).
    static func isSerialFallbackForced(env: [String: String]) -> Bool {
        guard let raw = env[serialFallbackEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static let serialFallbackForcedFromEnv =
        isSerialFallbackForced(env: ProcessInfo.processInfo.environment)

    /// Test hook: binds over the env flag for the duration of a task tree.
    /// Production never binds it (nil → env flag decides).
    @TaskLocal static var forceSerialOverride: Bool?

    static var effectiveForceSerial: Bool {
        forceSerialOverride ?? serialFallbackForcedFromEnv
    }

    // MARK: Safe-set predicate (rules 1-6 above)

    /// Full-Mac power surface — referenced from the dispatcher constants so
    /// the set cannot drift from the catalog (rule 2).
    static let fullMacSerialNames: Set<String> = Set(
        SwiftToolDispatcher.fullMacFileToolNames
            + SwiftToolDispatcher.fullMacSystemToolNames
            + SwiftToolDispatcher.fullMacAppToolNames
            + SwiftToolDispatcher.fullMacBuilderToolNames
            + SwiftToolDispatcher.fullMacRestartToolNames
    )

    /// Rule 3 — explicit serial names (state mutators, subprocess spawners,
    /// notify channels). claude_message/codex_message also trip the
    /// "message" keyword; listed anyway so the intent is visible.
    static let explicitSerialNames: Set<String> = [
        "tool_load", "tool_unload", "agent_swarm",
        "invoke_claude", "invoke_codex",
        "mac_notify", "mobile_notify", "mac.notify", "mobile.notify",
        "claude_message", "codex_message",
    ]

    /// Rule 5 — danger keywords, drawn from SecurityCenter.profile's
    /// classifier classes. NOT a verbatim mirror: SecurityCenter carves a
    /// read-only exception for messages_recent_threads that this veto
    /// deliberately does not replicate — stricter here is fail-safe (a
    /// vetoed read-only tool just runs serially). Any hit vetoes.
    static let dangerKeywords: [String] = [
        // shell class
        "shell", "terminal", "exec",
        // delete/destructive class
        "delete", "trash", "remove", "wipe", "erase", ".rm", "quarantine",
        // write class
        "write", "save", "create", "patch", "edit", "append", "promote",
        "install", "enable", "disable", "configure", "set_", "move",
        // system-control class
        "applescript", "jxa", "shortcut", "focus_app", "quit_app",
        "sleep", "lock_screen", "set_volume",
        // external-send class
        "send", "post", "tweet", "message", "reply",
        // money class
        "trade", "broker", "order", "buy", "sell", "wallet",
        // secrets class
        "secret", "credential", "token", "keychain",
    ]

    /// Rule 6 — SecurityCenter's safe_read keyword set.
    static let safeReadKeywords: [String] = [
        "read", "list", "search", "recall", "status", "get",
    ]

    /// Rule 6 fallback — audited read-only tools whose names carry no
    /// safe_read keyword. Keep tight; growing this list requires reading
    /// the tool's impl and confirming zero side effects.
    static let readOnlyAllowlist: Set<String> = [
        "time_now", "agent_introspect", "daemon_introspect",
        "recent_trace_summary", "tool_catalog",
        "web_fetch", "x_me", "x_timeline",
        "music_now_playing", "market_quote",
    ]

    /// The predicate. Input is the INTERNAL tool name (post
    /// ProviderToolNameMap reverse-mapping), matching what dispatch sees.
    static func isParallelSafe(internalToolName name: String) -> Bool {
        // Rule 1: external MCP tools — unknowable side effects.
        if name.hasPrefix("mcp__") { return false }
        // Rule 2: Full-Mac power surface.
        if fullMacSerialNames.contains(name) { return false }
        // Rule 3: explicit serial names.
        if explicitSerialNames.contains(name) { return false }
        // Rule 4: Mac Integration write-mode (same table the dispatch gate
        // uses).
        if ToolPreloadHeuristics.macIntegrationGates[name]?.mode == .write {
            return false
        }
        let lower = name.lowercased()
        // Rule 5: danger-keyword veto (incl. the rm_/mv_ prefix forms and
        // the ".set" suffix from SecurityCenter's classifier).
        if dangerKeywords.contains(where: { lower.contains($0) }) { return false }
        if lower.hasPrefix("rm_") || lower.hasPrefix("mv_") || lower.hasSuffix(".set") {
            return false
        }
        // Rule 6: positive read signal required (fail closed).
        if readOnlyAllowlist.contains(name) { return true }
        return safeReadKeywords.contains(where: { lower.contains($0) })
    }

    // MARK: Iteration planning

    /// One iteration's execution plan: consecutive parallel-safe indices
    /// coalesce into a `.concurrent` group (only when 2+ — a lone safe call
    /// runs serially so single-call iterations keep the exact serial event
    /// order); everything else is its own `.sequential` slot. Groups run in
    /// order; results always reassemble by original index.
    enum ExecutionGroup: Equatable {
        case concurrent([Int])
        case sequential(Int)
    }

    static func plan(parallelSafe: [Bool], forceSerial: Bool) -> [ExecutionGroup] {
        guard !forceSerial else {
            return parallelSafe.indices.map { .sequential($0) }
        }
        var groups: [ExecutionGroup] = []
        var run: [Int] = []
        func flushRun() {
            if run.count >= 2 {
                groups.append(.concurrent(run))
            } else {
                for idx in run { groups.append(.sequential(idx)) }
            }
            run = []
        }
        for (idx, safe) in parallelSafe.enumerated() {
            if safe {
                run.append(idx)
            } else {
                flushRun()
                groups.append(.sequential(idx))
            }
        }
        flushRun()
        return groups
    }
}

// MARK: - Parsed tool call

struct ParsedToolCall: Equatable {
    /// Provider-issued call id. Echoed back as `tool_result.tool_use_id`
    /// (Anthropic) or `function_call_output.call_id` (OpenAI). Empty when
    /// the parser couldn't recover one (legacy marker, bare JSON shape).
    let id: String
    let name: String
    let input: [String: JSONValue]
}

// MARK: - Parsing

struct ToolCallProtocolViolation: Equatable {
    enum Kind: Equatable {
        case markdownToolCallBlock
        case formattedToolUseMarker
    }

    let kind: Kind

    var modelFeedback: String {
        """
        NativeAgent tool protocol error: your previous response looked like a tool call but used Markdown formatting instead of the executable tool protocol. That response was not delivered and no tool was executed. Retry now by emitting only one or more exact <tool_use name="tool_name">{"arg":"value"}</tool_use> markers, with no Tool Call header, code fence, inline-code/emphasis wrapper, or invented Tool Result. If no tool is needed, answer the user directly.
        """
    }

    var terminalReply: String {
        "(tool protocol error: the model repeatedly formatted a tool call as Markdown; no formatted call was delivered or executed)"
    }
}

enum ToolCallParser {
    /// Try OpenAI shape first (whole-response JSON with tool_calls or
    /// function_call), then `<tool_use id="..." name="...">{json}</tool_use>`
    /// markers (both adapters emit this format), then bare JSON content
    /// blocks `{"type":"tool_use","id":...,"name":"...","input":{...}}`.
    static func parse(_ raw: String) -> [ParsedToolCall] {
        guard formattedToolCallViolation(in: raw) == nil else { return [] }
        if let openai = parseOpenAI(raw) {
            let executable = executableCalls(openai)
            if !executable.isEmpty { return executable }
        }
        let anth = executableCalls(parseAnthropic(raw))
        if !anth.isEmpty { return anth }
        return []
    }

    static func parseIncludingIgnorable(_ raw: String) -> [ParsedToolCall] {
        guard formattedToolCallViolation(in: raw) == nil else { return [] }
        if let openai = parseOpenAI(raw), !openai.isEmpty { return openai }
        let anth = parseAnthropic(raw)
        if !anth.isEmpty { return anth }
        return []
    }

    static func containsOnlyIgnorableCalls(_ raw: String) -> Bool {
        let calls = parseIncludingIgnorable(raw)
        return !calls.isEmpty && executableCalls(calls).isEmpty
    }

    /// Strip `<tool_use ...>...</tool_use>` markers from a raw response so the
    /// prose-only text can be persisted/surfaced. Both id-bearing and legacy
    /// plain-name forms are matched. Shared by the structured tool loop and the
    /// text-compatibility loop (C-L2, 2026-07-18 — formerly byte-identical twins).
    /// Announce-without-act detector (2026-07-19, Kimi K3 Telegram incident):
    /// weak-tool-discipline models end turns with an immediate-action promise
    /// ("on it — checking now") and ZERO tool calls, so nothing happens until
    /// the user prods. Deliberately CONSERVATIVE — short replies only, exact
    /// present-tense phrases; a question to the user or a long substantive
    /// answer never matches. False negatives cost one user nudge (status
    /// quo); false positives burn one extra provider call, so tight wins.
    static let unfulfilledPromisePhrases: [String] = [
        "checking now", "checking that now", "checking it now",
        "let me check", "let me look", "let me pull", "let me fetch",
        "let me grab", "let me see what",
        // Bare "on it." / "on it!" were raw-substring FPs ("I already acted on
        // it.") — dropped here (F2-M2). The em-dash/hyphen continuation forms
        // stay; the bare-acknowledgment case is handled by the final-sentence
        // "on it" gate in looksLikeUnfulfilledActionPromise.
        "on it —", "on it -",
        "i'll check", "i'll look", "i'll pull", "i'll fetch", "i'll dig",
        "looking now", "looking into it now", "pulling it up", "pulling that up",
        "loading it now", "loading them now", "loading that now", "fetching now",
        "give me a moment", "give me a sec", "one moment", "one sec",
    ]

    /// Shape rule (2026-07-19 round 2 — the phrase whitelist alone missed
    /// "going through the actual files now" and "Reading the README now." in
    /// the live incident): a progressive action verb followed within a clause
    /// by "now"/"next", not preceded by a completion word. Completion words
    /// ("just finished running now") stay valid stopping points.
    nonisolated(unsafe) private static let inProgressShapeRegex = try! NSRegularExpression(
        pattern: #"(?<!finished\s)(?<!done\s)(?<!just\s)(?<!already\s)(?<!stopped\s)\b(reading|checking|looking|going\s+through|pulling|fetching|loading|opening|scanning|digging|reviewing|inspecting|working\s+(?:on|through)|diving\s+(?:in|into)|taking\s+a\s+look|starting\s+(?:on|with))\b[^.!?\n]{0,60}\b(now|next)\b"#,
        options: [.caseInsensitive]
    )

    /// Round 4 (live incident: "Let me actually look at what's built." ended a
    /// turn — an adverb between "let me" and the verb defeated the literal
    /// phrase list). First-person immediate-intent with up to two intervening
    /// words, as the reply's FINAL sentence.
    /// F2-M3 (2026-07-23): go/take/see were REMOVED from the verb alternation —
    /// they bounced decision idioms ("I'll go with option A.", "I'll take that
    /// approach.", "let me see"). Their genuine action forms are already caught
    /// elsewhere ("go through" / "take a look" by inProgressShapeRegex, "let me
    /// see what" by the phrase list), so keeping them here only added FP risk.
    nonisolated(unsafe) private static let deferredIntentRegex = try! NSRegularExpression(
        pattern: #"\b(let\s+me|i'll|i\s+will|going\s+to|about\s+to)(\s+\w+){0,2}\s+(check|look|pull|fetch|grab|read|dig|scan|open|run|start|load)\b"#,
        options: [.caseInsensitive]
    )

    /// Completion-statement verbs: a final sentence containing one of these is
    /// a report, not a forward reference ("now the tests are green").
    private static let completionVerbTokens: Set<String> = [
        "is", "are", "was", "were", "be", "been", "done", "passed", "green",
        "complete", "completed", "finished", "works", "working", "ready",
        "found", "fixed", "ran", "looks", "shows", "has", "have",
    ]

    /// F2-M1 + F2-L2 (2026-07-23): a final sentence with a PLAIN PAST-TENSE main
    /// verb is a completed REPORT, never an in-progress promise — "Reviewing the
    /// PR, I left 3 comments.", "Running the benchmark took 4 seconds.", "Then
    /// the app crashed." The gerund-first and verbless-forward-reference rules
    /// FP'd on these because completionVerbTokens carried no past-tense reporting
    /// verbs. Detection: any `\w{3,}ed` form OR a curated set of common
    /// irregulars. Deliberately NARROW — future/progressive forms ("I'll go
    /// with") carry no past-tense token, so this exemption never fires on them
    /// and the deferred-intent / gerund rules still bite.
    private static let pastTenseIrregulars: Set<String> = [
        "left", "took", "ran", "went", "got", "found", "made", "saw", "gave",
        "sent", "wrote", "read", "built", "broke", "kept", "held", "came",
        "put", "set", "told", "said", "did",
    ]
    nonisolated(unsafe) private static let pastTenseEdRegex = try! NSRegularExpression(
        pattern: #"\b\w{3,}ed\b"#,
        options: [.caseInsensitive]
    )
    private static func finalSentenceIsPastTenseReport(_ finalSentence: String) -> Bool {
        let tokens = finalSentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if tokens.contains(where: { pastTenseIrregulars.contains($0) }) { return true }
        let range = NSRange(finalSentence.startIndex..., in: finalSentence)
        return pastTenseEdRegex.firstMatch(in: finalSentence, options: [], range: range) != nil
    }

    static func looksLikeUnfulfilledActionPromise(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 600 else { return false }
        // A genuine question back to the user is a valid stopping point.
        guard !trimmed.contains("?") else { return false }
        // F2-L1 (2026-07-23): fold curly apostrophes (U+2019, U+02BC) to ASCII
        // so the phrase list and the i'll / let me regexes match the smart-quote
        // variants weak models emit ("I’ll check", "let me…") identically.
        let lower = trimmed.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        // Final stopping sentence — HOISTED above the phrase check (F2-M2) so the
        // phrase list anchors to the terminal clause rather than the whole reply
        // (raw substring matched "on it." inside "I already acted on it.").
        let finalSentence = lower
            .split(whereSeparator: { ".!;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        // Phrase check (F2-M2): anchored to the final sentence, with an `already`
        // report exemption mirroring the regex lookbehinds — "I already acted on
        // it." claims the work is done, so it is a report, not a promise.
        if !finalSentence.contains("already") {
            if unfulfilledPromisePhrases.contains(where: { finalSentence.contains($0) }) {
                return true
            }
            // Bare "on it" only when it IS essentially the whole terminal clause
            // (starts the sentence, ≤4 words) — never a trailing "...acted on it."
            if finalSentence.hasPrefix("on it"),
               finalSentence.split(separator: " ").count <= 4 {
                return true
            }
        }
        let range = NSRange(lower.startIndex..., in: lower)
        if inProgressShapeRegex.firstMatch(in: lower, options: [], range: range) != nil {
            return true
        }
        // Round 5 — THE general announcement shape (live battery catch:
        // "Checking the transcript for that exchange before I answer." ended
        // a turn): a stopping sentence that BEGINS with a bare progressive
        // verb is an announcement — complete answers don't start with a
        // subjectless gerund. Subsumes most earlier shapes; completion-verb
        // stoplist still exempts reports ("Checking finished — all green").
        let gerundStarts: Set<String> = [
            "checking", "reading", "looking", "pulling", "fetching", "loading",
            "opening", "scanning", "digging", "reviewing", "inspecting",
            "searching", "grabbing", "running", "starting", "diving", "going",
        ]
        let fsWords = finalSentence.split(separator: " ").map(String.init)
        // Round 6 (live battery catch, 2026-07-20: "Now loading the
        // file/git/telegram tools so I can finish the battery for real."
        // ended a 20-call marathon turn at 11): a filler adverb in front of
        // the gerund slipped past the gerund-FIRST rule. Strip leading
        // filler tokens before the gerund check; the word-count bound
        // applies to what remains.
        let fillerLead: Set<String> = [
            "now", "next", "then", "first", "so", "and", "ok", "okay", "alright",
        ]
        let leadPunctuation = CharacterSet(charactersIn: ",:;—–-")
        let fsCore = Array(fsWords.drop(while: {
            fillerLead.contains($0.trimmingCharacters(in: leadPunctuation))
        }))
        if let first = fsCore.first, gerundStarts.contains(first),
           fsCore.count >= 2, fsCore.count <= 14,
           !fsCore.contains(where: { completionVerbTokens.contains($0) }),
           // F2-M1: "Running the benchmark took 4 seconds." / "Reviewing the PR,
           // I left 3 comments." are past-tense REPORTS despite the gerund lead.
           !finalSentenceIsPastTenseReport(finalSentence) {
            return true
        }
        // Adverb-tolerant deferred intent in the STOPPING sentence ("let me
        // actually look at what's built") — round 4.
        let fsRange = NSRange(finalSentence.startIndex..., in: finalSentence)
        if finalSentence.count <= 90,
           deferredIntentRegex.firstMatch(in: finalSentence, options: [], range: fsRange) != nil {
            return true
        }
        // Verbless forward-reference fragment as the STOPPING sentence
        // ("Now the issues and the code itself.") — round 3, live incident:
        // no progressive verb, no promise phrase, still an announced next
        // step with nothing delivered. Conservative: short final sentence,
        // starts with a forward word + determiner, zero completion verbs.
        let words = finalSentence.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 8 else { return false }
        let forwardStarts = ["now", "next", "then", "onto"]
        let determiners = ["the", "those", "these", "that", "to", "onto", "for", "into"]
        guard forwardStarts.contains(words[0]), determiners.contains(words[1]) else { return false }
        // F2-L2: "Then the app crashed." is a past-tense report, not a promise.
        if finalSentenceIsPastTenseReport(finalSentence) { return false }
        return !words.contains(where: { completionVerbTokens.contains($0) })
    }

    /// Completion-contract remedy for the STRUCTURED tool loop's announce-
    /// without-act bounce (F2-M4, 2026-07-23). The structured lane always speaks
    /// the provider's native tool-call convention, so the wording is modeled on
    /// the native-lane remedy at ChatOrchestrationClient+TextCompatibility —
    /// NEVER the text marker protocol.
    static func structuredAnnounceContractRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "NativeAgent completion contract: your reply describes work as in "
                + "progress but this runtime has NO background execution — work you "
                + "narrate without a tool call never happens, and the user is left "
                + "waiting. Continue NOW in this same turn: make the next tool call, "
                + "or deliver your complete final answer."
        }
        return "SECOND bounce — you again narrated instead of acting. This is your "
            + "last continuation: either make the tool call for the next step right "
            + "now, or give the user your complete final answer (including any "
            + "concrete blocker). Do not describe future work."
    }

    /// Empty-reply recovery remedy for the STRUCTURED tool loop (FIX 1, B1.1,
    /// 2026-07-23). Sibling of the text-compat `emptyReplyNudgeCount` recovery
    /// (ChatOrchestrationClient+TextCompatibility): a provider that returns an
    /// empty text reply AND zero tool calls (e.g. it did the whole move inside a
    /// thinking block and emitted no output) is not a valid final — nothing
    /// reached the user or the tool runtime. The structured lane always speaks
    /// the provider's native tool-call convention, so the wording mirrors the
    /// native-lane (`ridesNativeTools`) empty-reply nudge, NEVER the text marker
    /// protocol. Bounded at two bounces by the caller; the third empty reply is
    /// accepted as final so a provider that only ever thinks can never loop.
    static func structuredEmptyReplyRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "Your previous response contained only internal reasoning and "
                + "NO output — nothing reached the user or the tool runtime, so "
                + "whatever you decided never happened. Respond again NOW: either "
                + "make the tool call(s) for the action you chose, or deliver your "
                + "complete answer as plain prose. The response must never be empty."
        }
        return "SECOND empty response — again nothing reached the user or the tool "
            + "runtime. This is your last continuation: make the tool call(s) for "
            + "the next step right now, or deliver your complete final answer as "
            + "plain prose. Your response must not be empty."
    }

    static func stripToolUseMarkers(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"<tool_use\s+id="[^"]*"\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
            #"<tool_use\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        ]
        for pattern in patterns {
            if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = s as NSString
                s = rx.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }
        return s
    }

    static func executableCalls(_ calls: [ParsedToolCall]) -> [ParsedToolCall] {
        calls.filter { !isIgnorableToolName($0.name) }
    }

    static func isIgnorableToolName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ||
            trimmed == "..." ||
            trimmed == "…" ||
            trimmed == "tool_name" ||
            trimmed == "<tool_name>"
    }

    /// Markdown pseudo-tool calls are never executable. They previously fell
    /// through as ordinary assistant prose, which made a failed action look
    /// successful to both the model and the user. Keep the executable parser
    /// strict and let each tool-loop owner feed `modelFeedback` into its next
    /// provider call instead of surfacing the malformed response.
    static func formattedToolCallViolation(in raw: String) -> ToolCallProtocolViolation? {
        // A syntactically valid marker inside a code fence or inline Markdown
        // is still protocol-invalid. Check this before parseAnthropic, whose
        // intentionally unanchored marker regex otherwise finds the inner tag.
        let formattedMarkerPatterns = [
            #"(?is)(?:```|~~~)[^\r\n]*\r?\n\s*<tool_use\b[\s\S]*?</tool_use>\s*(?:```|~~~)"#,
            #"(?is)`\s*<tool_use\b[\s\S]*?</tool_use>\s*`"#,
            #"(?is)(?:\*\*|__)\s*<tool_use\b[\s\S]*?</tool_use>\s*(?:\*\*|__)"#,
        ]
        if formattedMarkerPatterns.contains(where: { regexMatches($0, in: raw) }) {
            return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
        }

        // Pin the real failure shape observed on Telegram:
        //   **Tool Call: codex_message**
        //   ```json
        //   { ... }
        //   ```
        // Requiring both an exact header line and a following fenced JSON
        // object avoids bouncing ordinary prose that merely discusses calls.
        let headerPattern = #"(?im)^[ \t]*(?:\d+[ \t]*)?(?:\*\*|__)?[ \t]*Tool[ \t]+Call[ \t]*(?::[ \t]*[A-Za-z0-9_.:-]*)?[ \t]*(?:\*\*|__)?[ \t]*$"#
        let fencedJSONPattern = #"(?is)(?:```|~~~)[ \t]*(?:json)?[ \t]*\r?\n[ \t]*\{[\s\S]*?(?:```|~~~)"#
        if regexMatches(headerPattern, in: raw), regexMatches(fencedJSONPattern, in: raw) {
            return ToolCallProtocolViolation(kind: .markdownToolCallBlock)
        }
        return nil
    }

    /// Earliest text that could become an executable or malformed tool
    /// protocol block. Streaming paths hold this suffix until the completed
    /// iteration can be parsed, so marker-shaped text never reaches a draft.
    static func earliestPotentialProtocolMarker(in raw: String) -> Range<String.Index>? {
        let needles = ["<tool", "**tool call", "__tool call", "tool call:"]
        var candidates = needles.compactMap { needle in
            raw.range(of: needle, options: [.caseInsensitive])
        }
        if let tool = raw.range(of: "<tool", options: [.caseInsensitive]) {
            let prefix = raw[..<tool.lowerBound]
            // Keep a surrounding Markdown wrapper too. Otherwise an opening
            // fence could stream just before the inner marker is recognized.
            for wrapper in ["```", "~~~", "**", "__", "`"] {
                if let start = prefix.range(of: wrapper, options: [.backwards]) {
                    candidates.append(start)
                }
            }
        }
        return candidates.min { $0.lowerBound < $1.lowerBound }
    }

    /// Bound the legacy grown-prompt echo while preserving enough of the
    /// model's rejected output to retry the intended tool and arguments.
    static func feedbackIncludingRejectedOutput(
        _ raw: String,
        violation: ToolCallProtocolViolation,
        limit: Int = 12_000
    ) -> String {
        let bounded: String
        if raw.count <= limit {
            bounded = raw
        } else {
            let end = raw.index(raw.startIndex, offsetBy: limit)
            bounded = String(raw[..<end]) + "\n[rejected output truncated]"
        }
        return """
        \(violation.modelFeedback)

        Rejected assistant output (for retry context only):
        \(bounded)
        """
    }

    private static func regexMatches(_ pattern: String, in raw: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.firstMatch(in: raw, range: range) != nil
    }

    // OpenAI: response body is a JSON object containing either
    //   "tool_calls": [{"id":..., "function":{"name":..., "arguments":"<json-string>"}}]
    // or
    //   "function_call": {"name":..., "arguments":"<json-string>"}
    static func parseOpenAI(_ raw: String) -> [ParsedToolCall]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else {
            return nil
        }
        if case .array(let arr) = obj["tool_calls"] ?? .null {
            var calls: [ParsedToolCall] = []
            for item in arr {
                guard case .object(let tc) = item else { continue }
                guard case .object(let fn) = tc["function"] ?? .null else { continue }
                guard case .string(let name) = fn["name"] ?? .null else { continue }
                let id: String = {
                    if case .string(let s) = tc["id"] ?? .null { return s }
                    return ""
                }()
                let input = extractArgumentsObject(fn["arguments"] ?? .null)
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
            return calls
        }
        if case .object(let fn) = obj["function_call"] ?? .null,
           case .string(let name) = fn["name"] ?? .null {
            let input = extractArgumentsObject(fn["arguments"] ?? .null)
            let id: String = {
                if case .string(let s) = fn["call_id"] ?? .null { return s }
                return ""
            }()
            return [ParsedToolCall(id: id, name: name, input: input)]
        }
        return nil
    }

    static func extractArgumentsObject(_ v: JSONValue) -> [String: JSONValue] {
        switch v {
        case .object(let o): return o
        case .string(let s):
            if let d = s.data(using: .utf8),
               let parsed = try? JSONValue.parse(d),
               case .object(let o) = parsed {
                return o
            }
            return [:]
        default: return [:]
        }
    }

    // <tool_use> marker (both OAuth-direct adapters emit) + bare JSON content
    // blocks (the Anthropic content-array shape). Marker is now id-bearing:
    //   <tool_use id="toolu_..." name="X">{json}</tool_use>
    // The legacy form `<tool_use name="X">{json}</tool_use>` is still parsed
    // — id falls back to empty so the tool loop can detect and skip the
    // round-trip ID echo.
    static func parseAnthropic(_ raw: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        // ID-bearing form FIRST so any legacy plain-name marker doesn't
        // greedy-consume an id-bearing block when both happen to be present.
        let idPattern = #"<tool_use\s+id="([^"]*)"\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#
        if let rx = try? NSRegularExpression(pattern: idPattern, options: []) {
            let ns = raw as NSString
            for m in rx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                let name = ns.substring(with: m.range(at: 2))
                let body = ns.substring(with: m.range(at: 3))
                var input: [String: JSONValue] = [:]
                if let d = body.data(using: .utf8),
                   let parsed = try? JSONValue.parse(d),
                   case .object(let o) = parsed {
                    input = o
                }
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
            if !calls.isEmpty { return calls }
        }
        // Legacy plain-name form. Kept as a back-compat seam.
        let legacyPattern = #"<tool_use\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#
        if let rx = try? NSRegularExpression(pattern: legacyPattern, options: []) {
            let ns = raw as NSString
            for m in rx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let body = ns.substring(with: m.range(at: 2))
                var input: [String: JSONValue] = [:]
                if let d = body.data(using: .utf8),
                   let parsed = try? JSONValue.parse(d),
                   case .object(let o) = parsed {
                    input = o
                }
                calls.append(ParsedToolCall(id: "", name: name, input: input))
            }
            if !calls.isEmpty { return calls }
        }
        // Bare JSON content-block / array shape.
        if let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let parsed = try? JSONValue.parse(d) {
            if case .array(let arr) = parsed {
                for item in arr {
                    if case .object(let o) = item,
                       case .string("tool_use") = o["type"] ?? .null,
                       case .string(let name) = o["name"] ?? .null {
                        let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                        var input: [String: JSONValue] = [:]
                        if case .object(let inObj) = o["input"] ?? .null { input = inObj }
                        calls.append(ParsedToolCall(id: id, name: name, input: input))
                    }
                }
            } else if case .object(let o) = parsed,
                      case .string("tool_use") = o["type"] ?? .null,
                      case .string(let name) = o["name"] ?? .null {
                let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                var input: [String: JSONValue] = [:]
                if case .object(let inObj) = o["input"] ?? .null { input = inObj }
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
        }
        return calls
    }
}

// MARK: - Lazy-tool-filter consolidation (C3)

extension TurnContext {
    /// Copy of this context with only `toolSchemas` replaced. The ONE
    /// manual-copy site for the 15 let-only fields — every lazy-filter rebuild
    /// routes through here so a newly added TurnContext field can't be silently
    /// dropped by a hand-inlined 15-field copy (the field-drop trap C3 closes).
    func withToolSchemas(_ newSchemas: [LLMToolSchema]) -> TurnContext {
        TurnContext(
            surface: surface,
            personaID: personaID,
            personaDocs: personaDocs,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            providerId: providerId,
            serviceTier: serviceTier,
            toolsAvailable: toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            toolSchemas: newSchemas,
            systemSegments: systemSegments,
            imageBlocks: imageBlocks,
            fluidContextTurn: fluidContextTurn
        )
    }
}

extension SwiftNativeTurnEngine {
    /// Derive the session's active-tools set (persisted ∪ turn-local; fail
    /// closed to turn-local only on an empty/nil session) and return `ctx` with
    /// its toolSchemas lazy-filtered to `alwaysOnCore ∪ active` (MCP schemas
    /// always pass). Single owner of the `persisted.union(turnActiveTools)`
    /// derivation + the filter + the rebuild that both structured loops and
    /// `streamTurn` used to hand-inline. Byte-identical to those inlines.
    /// `nonisolated` because it only reads the `activeToolsStore` `let`,
    /// task-locals, and pure statics — callable from `streamTurn`'s nonisolated
    /// task without an actor hop.
    nonisolated func lazyFilteredTurnContext(
        _ ctx: TurnContext,
        sessionId: String?,
        pinnedActiveTools: Set<String>? = nil
    ) async -> TurnContext {
        // pinnedActiveTools (2026-08-13, turn-context-iteration-cache): the
        // text-compat marker lane rebuilds context per tool iteration, and a
        // fresh ActiveToolsStore read here after a mid-turn `tool_load` grows
        // the tool catalog INSIDE the stable cache-breakpointed system
        // segment — byte-diff-proven to kill the Anthropic prefix cache for
        // the rest of the turn (369k cache-creation tokens on one live turn).
        // A caller that pins passes its turn-start set: the advertised
        // catalog stays byte-stable for the whole turn. Dispatchability is
        // NOT reduced — the lazy dispatch gate re-reads the store per call,
        // and tool_load's result already carries the loaded schemas
        // (schemas_added), so the model can use a just-loaded tool
        // immediately. Callers that need next-iteration list refresh (the
        // kimi native-tools lane, whose provider tools array is the only way
        // its model can call a tool) pass nil and keep the store read.
        let active: Set<String>
        if let pinnedActiveTools {
            active = pinnedActiveTools.union(LLMCallContext.turnActiveTools ?? [])
        } else {
            let trimmedSession = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSession.isEmpty {
                let persisted = await activeToolsStore.load(sessionId: trimmedSession).activeTools
                active = persisted.union(LLMCallContext.turnActiveTools ?? [])
            } else {
                active = LLMCallContext.turnActiveTools ?? []
            }
        }
        return SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: ctx, activeTools: active
        ) ?? ctx
    }
}

// MARK: - Loop

extension SwiftNativeTurnEngine {
    // MARK: - Shared turn-loop segments (C2)
    //
    // executeTurnWithToolLoop (blocking) and executeTurnWithStreamingToolLoop
    // (streaming) share the same scaffold: build/filter the turn context, seed
    // the conversation, run an iteration loop, and — on either a final reply or
    // exhaustion — record the outcome, run memory promotion, and build the
    // TurnEngineResult. The ONLY genuinely divergent segment is the per-iteration
    // PROVIDER STEP: the non-streaming loop does a blocking completeMessages with
    // an iteration-grain cancel-flag check (B7), while the streaming loop consumes
    // deltas live (emitting progress, buffering protocol markers, polling the
    // cancel flag per event) and cleans up streaming-only state on a protocol
    // violation. A single generic driver would have to push that delta/buffer/
    // violation-cleanup logic through a closure that also drives the loop's
    // continue/return control flow — a control-flow inversion that risks the
    // byte-identical event/yield/return contract the 709-test suite pins.
    //
    // So the four segments that ARE verbatim-shared are extracted here as helpers
    // (context resolution, completed-turn finish, post-dispatch round, exhausted-
    // turn finish); the provider step stays inline in each loop with a comment.
    // Every helper is byte-behavior-identical to the inline code it replaced.

    /// FIX 1 (B1.1): append an empty-reply nudge as a user turn. An empty reply
    /// leaves no assistant message, so a fresh `.user` message would follow the
    /// previous iteration's tool_result user message — two consecutive user
    /// turns, which the Anthropic wire rejects. Mirror the native-lane
    /// `appendNativeUserText` merge: fold the nudge into the trailing user
    /// message when one is present; otherwise stand it alone.
    static func appendStructuredUserNudge(_ text: String, to conversation: inout [LLMMessage]) {
        if let last = conversation.last, last.role == .user {
            conversation[conversation.count - 1] = LLMMessage(
                role: .user,
                content: last.content + [.text(text)]
            )
        } else {
            conversation.append(.user(text))
        }
    }

    /// Shared pre-loop context resolution. Prefer a caller-provided context
    /// (e.g. one already threaded with session history); otherwise build a fresh
    /// per-turn context AND lazy-filter ctx.toolSchemas through the session's
    /// active-tools set so the no-preBuiltContext path can't expose the full
    /// eager catalog. Then fire the context-snapshot event. Byte-identical to
    /// the inline both loops used.
    func resolveToolLoopContext(
        surface: String,
        userMessage: String,
        sessionId: String?,
        runId: String?,
        preBuiltContext: TurnContext?
    ) async throws -> TurnContext {
        let ctx: TurnContext
        if let preBuiltContext {
            ctx = preBuiltContext
        } else {
            let rawCtx = try await buildTurnContext(
                surface: surface,
                userMessage: userMessage,
                personaOverride: nil,
                imageBlocks: [],
                sessionID: sessionId
            )
            // Apply lazy-load filter (C3 shared helper):
            //   - non-empty sessionId: alwaysOnCore + sessionActive + MCP
            //   - empty/nil sessionId: alwaysOnCore + MCP only (fail closed)
            ctx = await lazyFilteredTurnContext(rawCtx, sessionId: sessionId)
        }
        Self.fireContextSnapshotEvent(
            surface: surface,
            context: ctx,
            sessionId: sessionId,
            runId: runId
        )
        return ctx
    }

    /// Shared terminal for a loop iteration that produced a final reply (no
    /// executable tool calls): record the completed outcome, run the realtime
    /// memory-promotion side channel (production chat goes through this loop, so
    /// without it AdaptiveMemoryPromoter never sees the user/assistant pair), and
    /// build the TurnEngineResult. Identical to the empty-calls returns both
    /// loops inlined; `rawLLMResponse` differs per path (non-streaming passes the
    /// iteration `raw`, streaming the accumulated `lastRawResponse`), so it's a
    /// parameter.
    func finishCompletedTurn(
        reply: String,
        ctx: TurnContext,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        rawLLMResponse: String,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String
    ) async -> TurnEngineResult {
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        await observeMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: reply,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: reply,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount
        )
    }

    /// Result of a shared post-dispatch round: `.stopLoop` when the no-progress
    /// guard tripped (caller breaks BEFORE the next-iteration prep, exactly as
    /// the inlined code did), `.continueLoop` otherwise.
    enum ToolDispatchRoundOutcome { case continueLoop, stopLoop }

    /// Shared post-provider-call round for both structured loops: mint the
    /// assistant message (prose + tool_use blocks, synthesizing collision-free
    /// ids for id-less calls), dispatch the iteration's calls through the shared
    /// core, append the paired tool_result user message, run the no-progress
    /// guard, and — unless a stop was raised — refresh same-turn tool schemas and
    /// age older tool-result bodies (compat-only). Byte-identical to both inlines;
    /// the streaming path flushes its pending prose delta BEFORE calling this.
    func runToolDispatchRound(
        providerCalls: [ParsedToolCall],
        iterationRawText: String,
        ctx: TurnContext,
        surface: String,
        sessionId: String?,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?,
        conversation: inout [LLMMessage],
        dispatches: inout [TurnEngineResult.ToolDispatchRecord],
        activeToolSchemas: inout [LLMToolSchema],
        providerTools: inout ProviderToolNameMap,
        noProgressGuard: inout ToolLoopNoProgressGuard,
        loopRecoveryReply: inout String?
    ) async -> ToolDispatchRoundOutcome {
        // Append the assistant turn that contained the tool calls. Strip any
        // <tool_use> markers from the surfaced text so the assistant text block
        // carries only the model's prose (the structured toolUse blocks below
        // carry the actual tool calls).
        let prose = ToolCallParser.stripToolUseMarkers(iterationRawText).trimmingCharacters(in: .whitespacesAndNewlines)
        var assistantBlocks: [LLMContentBlock] = []
        if !prose.isEmpty {
            assistantBlocks.append(.text(prose))
        }
        // If the parser didn't recover an id (legacy marker), mint a stable one
        // keyed on round base + call index + name so the provider has SOMETHING
        // to round-trip. The index matters: two id-less calls to the SAME tool in
        // one round must not collide (audit 2026-06-09). pairedIds keeps the
        // result side echoing the exact assistant-side id by position.
        let roundBase = dispatches.count
        var pairedIds: [String] = []
        for (idx, call) in providerCalls.enumerated() {
            let argsJSON: Data = {
                if let v = try? JSONValue.object(call.input).serializedData(pretty: false) {
                    return v
                }
                return Data("{}".utf8)
            }()
            let id = call.id.isEmpty
                ? "toolu_synth_\(roundBase + idx)_\(call.name)"
                : call.id
            pairedIds.append(id)
            assistantBlocks.append(.toolUse(id: id, name: call.name, inputJSON: argsJSON))
        }
        conversation.append(LLMMessage(role: .assistant, content: assistantBlocks))

        // Dispatch the iteration's calls (parallel-safe runs concurrent, cap 4,
        // everything else serial in order — U1 step 6) and append the results as
        // ONE user message of tool_result blocks paired by id in original order.
        var (toolResultBlocks, iterationRecords) = await dispatchIterationCalls(
            providerCalls: providerCalls,
            pairedIds: pairedIds,
            providerTools: providerTools,
            modelId: ctx.modelId,
            surface: surface,
            sessionId: sessionId,
            personaID: ctx.personaID,
            fluidContextTurn: ctx.fluidContextTurn,
            tools: tools,
            progress: progress
        )
        dispatches.append(contentsOf: iterationRecords)
        switch noProgressGuard.observe(iterationRecords) {
        case .none:
            break
        case .warn(let feedback):
            await progress?(.notice(kind: "tool_loop_recovery", text: feedback))
            // 2026-07-21 audit fix: the WARN text is model-directed
            // guidance ("change the arguments, use a narrower query or a
            // different tool...") but only the USER ever saw it — the
            // model repeated identical rounds 9-15 with zero corrective
            // signal until the hard stop (whose feedback IS appended).
            // Feed it into the conversation like the stop branch does.
            toolResultBlocks.append(.text(feedback))
        case .stop(let feedback):
            toolResultBlocks.append(.text(feedback))
            loopRecoveryReply = feedback
        }
        conversation.append(LLMMessage(role: .user, content: toolResultBlocks))
        if loopRecoveryReply != nil { return .stopLoop }
        if SameTurnToolSchemaRefresh.wasRequested(calls: providerCalls, providerTools: providerTools) {
            activeToolSchemas = await SameTurnToolSchemaRefresh.afterLoad(
                current: activeToolSchemas,
                sessionId: sessionId,
                tools: tools,
                activeToolsStore: activeToolsStore
            )
            providerTools = ProviderToolNameMap(activeToolSchemas)
        }
        // U1 step 5 + item 8 (review fix): the sweep mutates bytes inside the
        // trailing-message cached prefix, so it fires ONLY in compat mode (no
        // message breakpoint). Default shape leaves the conversation byte-stable
        // and lets prefix caching pay.
        if AnthropicOAuthDirectAdapter.GrownPromptCompat.effective {
            IntraTurnToolResultClearing.sweep(&conversation)
        }
        return .continueLoop
    }

    /// Shared exhaustion tail for a loop that ran out of iterations without a
    /// final reply: pick the best-effort reply (loop-recovery stop > protocol-
    /// violation terminal > exhaustion fallback when there's no usable prose or
    /// the last raw was only a structured tool call > the stripped fallback
    /// text), record the abandoned outcome, run memory promotion, and build the
    /// result. The streaming path also treats a streamed tool-call round as
    /// "only a structured tool call", so that extra signal is a parameter
    /// (default false → byte-identical to the non-streaming inline).
    func finishExhaustedTurn(
        ctx: TurnContext,
        lastRawResponse: String,
        lastProtocolViolation: ToolCallProtocolViolation?,
        loopRecoveryReply: String?,
        iterationLimit: Int,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        additionalStructuredToolCallSignal: Bool = false
    ) async -> TurnEngineResult {
        let fallbackText = ToolCallParser.stripToolUseMarkers(lastRawResponse).trimmingCharacters(in: .whitespacesAndNewlines)
        let recalledIds = ctx.resolvedRecalledIds
        let rawWasOnlyStructuredToolCall = additionalStructuredToolCallSignal
            || !ToolCallParser.parse(lastRawResponse).isEmpty
        let final: String
        if let loopRecoveryReply {
            final = loopRecoveryReply
        } else if let lastProtocolViolation {
            final = lastProtocolViolation.terminalReply
        } else if fallbackText.isEmpty || rawWasOnlyStructuredToolCall {
            final = ToolLoopExhaustion.fallbackReply(
                iterationLimit: iterationLimit, dispatchCount: dispatches.count
            )
        } else {
            final = fallbackText
        }
        await ctx.fluidContextTurn?.recordRetry()
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        await observeMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: final,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: final,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: lastRawResponse,
            providerCallCount: providerCallCount
        )
    }

    /// Execute one turn with a tool-dispatch loop. See file header for carves.
    ///
    /// `llm` and `tools` must be the SAME instances passed to the engine's
    /// initializer — they're parameters here only because the actor's stored
    /// llm/tools are `private` and we are not touching the base file.
    public func executeTurnWithToolLoop(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        runId: String? = nil,
        maxIterations: Int? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        // B7 (2026-07-17): a cross-process Stop that only WRITES the session's
        // cancelled.flag (no Task handle — e.g. the bridge surface) must be able
        // to halt a NON-streaming structured turn between provider calls, just
        // like the streaming loop's per-event poll. nil → legacy behavior (no
        // cross-process cancel), so existing callers are byte-identical.
        cancelFlagPath: URL? = nil
    ) async throws -> TurnEngineResult {
        // P2-3: fold the Workshop surface once at the loop entry (see
        // buildTurnContext) so the whole tool loop threads one vocabulary.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        // An image-only turn (no caption text) is valid when the pre-built
        // context carries image blocks — don't reject it as empty.
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (preBuiltContext?.imageBlocks.isEmpty ?? true) {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Shared pre-loop context resolution (C2): prefer preBuiltContext, else
        // build + lazy-filter through the session's active tools, then fire the
        // context-snapshot event.
        let ctx = try await resolveToolLoopContext(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            runId: runId,
            preBuiltContext: preBuiltContext
        )

        // HOTFIX 2026-06-03 conversation-shape: was single-prompt mutation
        // ("prompt += Tool X returned: ..."), which left the model without
        // PAIRED tool_use/tool_result blocks each round — it kept re-emitting
        // the same tool call up to maxIterations and never produced a final
        // reply. Now we build a structured [LLMMessage] conversation and
        // route via llm.completeMessages, which the OAuth-direct adapters
        // override to emit canonical wire shape for each provider.
        // Image blocks ride on the CURRENT user message ONLY (per-turn DYNAMIC)
        // — never persisted, never re-sent. Empty → exact pre-multimodal shape.
        var conversation: [LLMMessage] = ctx.imageBlocks.isEmpty
            ? [.user(ctx.userMessage)]
            : [.userWithImages(ctx.userMessage, images: ctx.imageBlocks)]
        var activeToolSchemas = ctx.toolSchemas
        var providerTools = ProviderToolNameMap(activeToolSchemas)
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var lastRawResponse: String = ""
        var lastProtocolViolation: ToolCallProtocolViolation?
        // 2026-07-21 audit fix: bound the violation bounce (same cap as the
        // streaming loop and text-compat — third violation accepted as final
        // via the exhausted finish's terminalReply).
        var violationNudgeCount = 0
        // F2-M4 (2026-07-23): the completion-contract announce-without-act
        // bounce, hoisted from the text-compat call site into the STRUCTURED
        // lane so missions/workshop/bridge + every OpenAI-wire provider enforce
        // it too (not just prompt-only). Same cap as text-compat: at most TWICE
        // per turn, then the third announcement is accepted as final so a model
        // that refuses to act can never loop.
        var announceNudgeCount = 0
        // FIX 1 (B1.1, 2026-07-23): empty-reply recovery, ported from the
        // text-compat lane's `emptyReplyNudgeCount` into the STRUCTURED loop. An
        // empty text reply + zero tool calls is not a valid final; nudge at most
        // twice, then accept so a thinking-only provider can never loop.
        var emptyReplyNudgeCount = 0
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        var providerCallCount = 0
        let iterationLimit = ToolLoopBudget.resolve(surface: surface, requested: maxIterations)

        for _ in 0..<iterationLimit {
            // B7: cross-process Stop between provider calls. A bridge-surface
            // Stop that only WROTE cancelled.flag (no Task handle) halts the
            // turn here instead of running to iterationLimit burning tokens.
            // Mirrors the streaming loop's mid-stream poll, at iteration grain.
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw CancellationError()
            }
            // U1 step 4: thread the session id task-locally so the OpenAI
            // Responses adapter can derive a stable per-session
            // prompt_cache_key (additive; nil binding = pre-U1 behavior).
            // U1 step 2b/3b: thread the stable/dynamic system split the same
            // way so the Anthropic adapters can place the sys cache
            // breakpoint at the stable-segment end (nil = combined block).
            providerCallCount += 1
            let providerRoute = ctx.providerId ?? LLMCallContext.providerId
            let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
            let raw: String
            do {
            raw = try await LLMCallContext.$providerId.withValue(providerRoute) {
            try await LLMCallContext.$serviceTier.withValue(serviceTier) {
            try await LLMCallContext.$systemSegments.withValue(ctx.systemSegments) {
                try await LLMCallContext.$sessionId.withValue(sessionId) {
                    try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
                    try await llm.completeMessages(
                        messages: conversation,
                        system: ctx.systemPrompt,
                        model: ctx.modelId,
                        surface: surface,
                        tools: providerTools.schemas.isEmpty ? nil : providerTools.schemas
                    )
                    }
                }
            }
            }
            }
            } catch {
                // A provider failure after this turn already dispatched tools
                // must not be whole-turn-replayed by surface retry ladders.
                throw ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: dispatches.count)
            }
            lastRawResponse = raw
            if let violation = ToolCallParser.formattedToolCallViolation(in: raw) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 { break }
                // Reflect the rejected assistant output back as conversation
                // state, then give the model a precise protocol error. Nothing
                // is dispatched, persisted, promoted, or returned to a surface.
                conversation.append(.assistantText(raw))
                conversation.append(.user(violation.modelFeedback))
                continue
            }
            lastProtocolViolation = nil
            let providerCalls = ToolCallParser.executableCalls(ToolCallParser.parse(raw))
            if providerCalls.isEmpty {
                let reply = ToolCallParser.containsOnlyIgnorableCalls(raw)
                    ? ToolCallParser.stripToolUseMarkers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    : raw
                // FIX 1 (B1.1): empty-reply recovery — checked BEFORE the announce
                // bounce. An empty text reply + empty tool calls is not a valid
                // final; nudge (max 2) then accept. An empty string can never
                // match looksLikeUnfulfilledActionPromise (it guards
                // `!trimmed.isEmpty`), so the two bounces never contend. An empty
                // reply produces no assistant text, so the remedy is folded into
                // the trailing user message when one is present (mirrors the
                // native-lane appendNativeUserText merge) to keep wire roles
                // alternating; otherwise it stands alone.
                if emptyReplyNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyReplyNudgeCount += 1
                    let remedy = ToolCallParser.structuredEmptyReplyRemedy(
                        secondBounce: emptyReplyNudgeCount == 2
                    )
                    Self.appendStructuredUserNudge(remedy, to: &conversation)
                    continue
                }
                // F2-M4: completion-contract bounce. Only when tools are actually
                // available to call (else the model has nothing to act with) and
                // at most twice per turn. Preserves the exact terminal behavior
                // for turns WITH tool calls — this block is calls-empty only.
                if announceNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(reply) {
                    announceNudgeCount += 1
                    conversation.append(.assistantText(raw))
                    conversation.append(.user(
                        ToolCallParser.structuredAnnounceContractRemedy(
                            secondBounce: announceNudgeCount == 2
                        )
                    ))
                    continue
                }
                // Shared completed-turn finish (C2): records .completed, runs the
                // realtime memory-promotion side channel, builds the result.
                return await finishCompletedTurn(
                    reply: reply,
                    ctx: ctx,
                    dispatches: dispatches,
                    startNs: startNs,
                    rawLLMResponse: raw,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    surface: surface
                )
            }
            // Shared post-dispatch round (C2): assistant blocks → dispatch →
            // no-progress guard → paired tool_result append → schema refresh +
            // compat-only sweep. `.stopLoop` means the guard tripped; break
            // BEFORE the next-iteration prep, exactly as the inline code did.
            let outcome = await runToolDispatchRound(
                providerCalls: providerCalls,
                iterationRawText: raw,
                ctx: ctx,
                surface: surface,
                sessionId: sessionId,
                tools: tools,
                progress: progress,
                conversation: &conversation,
                dispatches: &dispatches,
                activeToolSchemas: &activeToolSchemas,
                providerTools: &providerTools,
                noProgressGuard: &noProgressGuard,
                loopRecoveryReply: &loopRecoveryReply
            )
            if case .stopLoop = outcome { break }
        }
        // Loop exhausted. Shared exhaustion tail (C2): best-effort final reply
        // from the last raw response + dispatch trail rather than throwing, so
        // the caller still gets SOMETHING usable.
        return await finishExhaustedTurn(
            ctx: ctx,
            lastRawResponse: lastRawResponse,
            lastProtocolViolation: lastProtocolViolation,
            loopRecoveryReply: loopRecoveryReply,
            iterationLimit: iterationLimit,
            dispatches: dispatches,
            startNs: startNs,
            providerCallCount: providerCallCount,
            userMessage: userMessage,
            sessionId: sessionId,
            surface: surface
        )
    }

    /// Streaming sibling of executeTurnWithToolLoop. It preserves the same
    /// structured tool_use/tool_result conversation shape, but consumes
    /// provider text deltas and tool-call events as they arrive so app chat
    /// surfaces do not look dead while a tool-capable response is running.
    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        runId: String? = nil,
        maxIterations: Int? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        cancelFlagPath: URL? = nil
    ) async throws -> TurnEngineResult {
        // Image-only turn (no caption) is valid when the pre-built context
        // carries image blocks.
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (preBuiltContext?.imageBlocks.isEmpty ?? true) {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Shared pre-loop context resolution (C2): same build + lazy-filter +
        // snapshot as the non-streaming path so the streaming surface doesn't
        // ship the full eager catalog either.
        let ctx = try await resolveToolLoopContext(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            runId: runId,
            preBuiltContext: preBuiltContext
        )

        var conversation: [LLMMessage] = ctx.imageBlocks.isEmpty
            ? [.user(ctx.userMessage)]
            : [.userWithImages(ctx.userMessage, images: ctx.imageBlocks)]
        var activeToolSchemas = ctx.toolSchemas
        var providerTools = ProviderToolNameMap(activeToolSchemas)
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var lastRawResponse = ""
        // #5: visible prose accumulated across iterations (text deltas only, no
        // tool markers) — carried across a mid-stream throw so the partial isn't
        // lost. Used only on the failure path.
        var visibleText = ""
        // Transcript-loss fix (2026-07-31): interstitial narration from every
        // NON-final iteration (prose → tool → prose → tool → prose). Those bytes
        // were streamed to the surface but the success return built `reply` from
        // the LAST iteration's `iterAccumulated` only, so a reload showed one
        // paragraph where the user watched three render. The failure path already
        // persisted the whole accumulated `visibleText`; success now matches it —
        // raw concatenation, no injected separator, exactly the bytes emitted via
        // progress?(.delta(...)). Bounced iterations (violation / empty-reply /
        // announce) `continue` before the append, so rejected narration is
        // discarded here the same way those paths reset `visibleText`.
        var turnInterstitialProse = ""
        var lastProviderHadToolCalls = false
        var lastProtocolViolation: ToolCallProtocolViolation?
        // 2026-07-21 audit fix: bound the violation bounce — a
        // deterministically malformed model could violate EVERY iteration and
        // burn the whole iteration budget (violation rounds dispatch zero
        // tools, so the no-progress guard never fires). Third violation is
        // accepted as final: break into the exhausted finish, which yields
        // lastProtocolViolation.terminalReply.
        var violationNudgeCount = 0
        // F2-M4 (2026-07-23): completion-contract announce-without-act bounce on
        // the structured streaming lane (mirrors the non-streaming sibling and
        // the text-compat call site). Bounded at two; third announcement final.
        var announceNudgeCount = 0
        // FIX 1 (B1.1, 2026-07-23): empty-reply recovery on the streaming lane —
        // sibling of the non-streaming loop and the text-compat lane. Bounded at
        // two; third empty reply accepted as final.
        var emptyReplyNudgeCount = 0
        var emittedProviderFirstDelta = false
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        // B3 (2026-07-17): the streaming loop is the PRIMARY chat path but never
        // counted provider calls — cost/telemetry undercounted the main surface.
        // One streamMessages call per iteration; count it like the non-streaming
        // loop does, and thread it into both TurnEngineResult returns below.
        var providerCallCount = 0
        let iterationLimit = ToolLoopBudget.resolve(surface: surface, requested: maxIterations)

        for _ in 0..<iterationLimit {
            providerCallCount += 1
            var iterAccumulated = ""
            // Bytes this iteration actually handed to the surface (marker-safe
            // slices only). Folded into `turnInterstitialProse` when the
            // iteration ends in a tool dispatch.
            var iterEmittedProse = ""
            var streamedCalls: [ParsedToolCall] = []
            var pendingProtocolDelta = ""
            // U1 step 4: thread the session id task-locally so the OpenAI
            // Responses adapter gets a stable prompt_cache_key. U1 step 2b/3b:
            // same for the stable/dynamic system split (Anthropic adapters'
            // breakpoint placement).
            // MEMORY-SAFETY (2026-07-04): bind via the ASYNC withValue overload
            // wrapping BOTH construction AND consumption — NOT a sync withValue
            // around construction alone. llm.streamMessages(...) builds an
            // AsyncThrowingStream whose adapter child Task inherits these
            // task-locals and reads them LAZILY (e.g. sessionId → prompt_cache_key
            // in buildResponsesBodyFromMessages, after streamMessages has already
            // returned). A sync withValue pops the binding the instant the stream
            // is constructed — while the child still references it — the same
            // task-allocator LIFO shape ("freed pointer was not the last
            // allocation" / swift_task_dealloc_specific) that caused the
            // release-only first-chat crash on the text-compat path (1b1caf58).
            // The async overload holds the binding until the stream is fully
            // drained (child Task done), keeping the pop LIFO-ordered. The
            // no-tool-calls early return + tool dispatch stay OUTSIDE this block,
            // so wrapping only construction+consumption needs no re-indent.
            let providerRoute = ctx.providerId ?? LLMCallContext.providerId
            let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
            try await LLMCallContext.$providerId.withValue(providerRoute) {
            try await LLMCallContext.$serviceTier.withValue(serviceTier) {
            try await LLMCallContext.$systemSegments.withValue(ctx.systemSegments) {
            try await LLMCallContext.$sessionId.withValue(sessionId) {
            try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
            let stream = llm.streamMessages(
                messages: conversation,
                system: ctx.systemPrompt,
                model: ctx.modelId,
                surface: surface,
                tools: providerTools.schemas.isEmpty ? nil : providerTools.schemas
            )
            var streamEventIndex = 0
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    streamEventIndex += 1
                    // #19 (2026-06-14): a cross-process Stop that only WRITES the
                    // cancelled.flag (no Task handle — e.g. the bridge surface)
                    // must be able to halt a structured turn, else it runs to
                    // completion burning provider tokens. Mirror streamTurn's poll.
                    if let flag = cancelFlagPath,
                       streamEventIndex % 8 == 0,
                       FileManager.default.fileExists(atPath: flag.path) {
                        throw CancellationError()
                    }
                    switch event {
                    case .textDelta(let delta):
                        if !delta.isEmpty, !emittedProviderFirstDelta {
                            emittedProviderFirstDelta = true
                            TurnLifecycleTelemetry.emit(
                                .providerFirstDelta,
                                surface: surface,
                                sessionId: sessionId,
                                observedBy: "structured_tool_loop.stream"
                            )
                        }
                        iterAccumulated += delta
                        lastRawResponse += delta
                        visibleText += delta
                        pendingProtocolDelta += delta
                        if let marker = ToolCallParser.earliestPotentialProtocolMarker(
                            in: pendingProtocolDelta
                        ) {
                            let safe = String(pendingProtocolDelta[..<marker.lowerBound])
                            pendingProtocolDelta = String(pendingProtocolDelta[marker.lowerBound...])
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await progress?(.delta(safe))
                            }
                        } else if pendingProtocolDelta.count > 16 {
                            // Preserve a short cross-chunk tail so a marker
                            // split at an arbitrary SSE boundary is detected
                            // before any part of it reaches the surface.
                            let split = pendingProtocolDelta.index(
                                pendingProtocolDelta.endIndex,
                                offsetBy: -16
                            )
                            let safe = String(pendingProtocolDelta[..<split])
                            pendingProtocolDelta = String(pendingProtocolDelta[split...])
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await progress?(.delta(safe))
                            }
                        }
                    case .toolCall(let call):
                        guard !ToolCallParser.isIgnorableToolName(call.name) else {
                            continue
                        }
                        let input: [String: JSONValue] = {
                            guard let parsed = try? JSONValue.parse(call.inputJSON),
                                  case .object(let object) = parsed else {
                                return [:]
                            }
                            return object
                        }()
                        streamedCalls.append(ParsedToolCall(id: call.id, name: call.name, input: input))
                        let args = String(data: call.inputJSON, encoding: .utf8) ?? "{}"
                        lastRawResponse += "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
                    case .keepAlive:
                        // Liveness signal (no content): nothing to accumulate and
                        // no progress delta to emit. The cancel-flag poll above
                        // still ran, so a keepalive is also a valid stop checkpoint.
                        break
                    }
                }
            } catch is CancellationError {
                // 2026-07-21 audit fix: a user stop mid-stream CARRIES the
                // visible partial (marker-stripped, same as the interrupted
                // path below) so the orchestration catch can persist it with
                // cancelled:true — previously this lane dropped every
                // streamed character on Stop while text-compat persisted it.
                // Cancel still propagates as cancel semantics (not a
                // failure) via the dedicated case.
                let safePartial: String
                if let r = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                    safePartial = String(visibleText[..<r.lowerBound])
                } else {
                    safePartial = visibleText
                }
                throw TurnEngineError.streamCancelled(
                    partial: safePartial,
                    underlying: CancellationError()
                )
            } catch {
                // #5 (2026-06-14): a mid-stream provider failure must not silently
                // DROP the prose the user already watched render. Carry the visible
                // partial across the throw so the orchestration catch can persist
                // it (cancelled:false). Strip any tool marker first — some
                // structured-path providers emit <tool_use> as TEXT (the
                // streamedCalls.isEmpty fallback below parses it), so visibleText
                // can hold a raw/partial marker that must NOT persist as visible
                // prose (gpt-5.5 review 2026-06-14).
                let safePartial: String
                if let r = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                    safePartial = String(visibleText[..<r.lowerBound])
                } else {
                    safePartial = visibleText
                }
                // Wrap the UNDERLYING only: `case .streamInterrupted(partial, _)`
                // pattern-matches upstream still fire (partial persistence), and
                // streamInterrupted's errorDescription flows the wrapped marker
                // through to surface retry ladders.
                throw TurnEngineError.streamInterrupted(
                    partial: safePartial,
                    underlying: ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: dispatches.count)
                )
            }
            } // LLMCallContext.$reasoningEffort.withValue
            } // LLMCallContext.$sessionId.withValue
            } // LLMCallContext.$systemSegments.withValue
            } // LLMCallContext.$serviceTier.withValue
            } // LLMCallContext.$providerId.withValue

            if let violation = ToolCallParser.formattedToolCallViolation(in: iterAccumulated) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 { break }
                lastProviderHadToolCalls = false
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                lastRawResponse = ""
                if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                    visibleText = String(visibleText[..<marker.lowerBound])
                } else {
                    visibleText = ""
                }
                conversation.append(.assistantText(iterAccumulated))
                conversation.append(.user(violation.modelFeedback))
                continue
            }
            lastProtocolViolation = nil
            let providerCalls = ToolCallParser.executableCalls(streamedCalls.isEmpty
                ? ToolCallParser.parse(iterAccumulated)
                : streamedCalls)
            lastProviderHadToolCalls = !providerCalls.isEmpty
            if providerCalls.isEmpty {
                let reply = ToolCallParser.containsOnlyIgnorableCalls(iterAccumulated)
                    ? ToolCallParser.stripToolUseMarkers(iterAccumulated).trimmingCharacters(in: .whitespacesAndNewlines)
                    : iterAccumulated
                // FIX 1 (B1.1): empty-reply recovery, checked BEFORE the announce
                // bounce. Empty text + empty tool calls is not a valid final;
                // nudge (max 2) then accept. Resets the accumulated stream state
                // exactly like the announce/violation siblings so the re-prompted
                // response cannot leak into the next iteration. An empty string
                // can never match looksLikeUnfulfilledActionPromise, so the two
                // bounces never contend.
                if emptyReplyNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyReplyNudgeCount += 1
                    Self.appendStructuredUserNudge(
                        ToolCallParser.structuredEmptyReplyRemedy(
                            secondBounce: emptyReplyNudgeCount == 2
                        ),
                        to: &conversation
                    )
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                    lastRawResponse = ""
                    lastProviderHadToolCalls = false
                    if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                        visibleText = String(visibleText[..<marker.lowerBound])
                    } else {
                        visibleText = ""
                    }
                    continue
                }
                // F2-M4: completion-contract bounce, BEFORE flushing the pending
                // delta as final. Only when tools are available and at most
                // twice per turn. On a bounce, reset the accumulated stream state
                // exactly like the protocol-violation path above so this
                // re-prompted response cannot leak into the next iteration.
                //
                // KNOWN PARITY LIMITATION (gpt-5.5 round-3 review, accepted):
                // deltas already flushed past the 16-char holdback may have
                // surfaced part of the rejected narration before this bounce
                // runs; the accepted continuation then streams after it. The
                // text-compat lane has behaved this way since the detector
                // shipped. A true fix needs a retract/reset TurnStreamEvent
                // honored by every consumer surface — tracked on the round-3
                // board as a design item, not silently absorbed here. Buffering
                // all deltas until iteration-accept was rejected: it would turn
                // every streaming turn into chunk-at-end delivery.
                if announceNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(reply) {
                    announceNudgeCount += 1
                    conversation.append(.assistantText(iterAccumulated))
                    conversation.append(.user(
                        ToolCallParser.structuredAnnounceContractRemedy(
                            secondBounce: announceNudgeCount == 2
                        )
                    ))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                    lastRawResponse = ""
                    lastProviderHadToolCalls = false
                    if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                        visibleText = String(visibleText[..<marker.lowerBound])
                    } else {
                        visibleText = ""
                    }
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(pendingProtocolDelta))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                }
                // Shared completed-turn finish (C2). Streaming passes the
                // accumulated lastRawResponse as rawLLMResponse (vs the
                // non-streaming iteration `raw`).
                //
                // The PERSISTED reply is every visible byte of the turn — the
                // narration streamed before each tool round plus this final
                // iteration's text — not just the last iteration. Single-round
                // turns leave `turnInterstitialProse` empty, so they persist
                // exactly `reply` as before.
                return await finishCompletedTurn(
                    reply: turnInterstitialProse + reply,
                    ctx: ctx,
                    dispatches: dispatches,
                    startNs: startNs,
                    rawLLMResponse: lastRawResponse,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    surface: surface
                )
            }

            let pendingProse = ToolCallParser.stripToolUseMarkers(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            pendingProtocolDelta.removeAll(keepingCapacity: true)
            // This iteration is committed (it dispatches tools, so it can never
            // be rewound by a bounce): keep its narration for the persisted
            // reply.
            //
            // ONLY when the provider streamed STRUCTURED tool calls. If the
            // calls were instead recovered by parsing the iteration's TEXT, that
            // text IS the call encoding — an XML <tool_use> marker or a raw
            // {"tool_calls":[…]} payload depending on dialect — and must never
            // land in the transcript as prose. stripToolUseMarkers only knows
            // the XML dialect, so text-parsed iterations contribute nothing at
            // all, exactly as before this fix.
            if !streamedCalls.isEmpty {
                turnInterstitialProse += ToolCallParser.stripToolUseMarkers(iterEmittedProse)
            }
            // Shared post-dispatch round (C2): identical to the non-streaming
            // loop — assistant blocks → shared dispatch core → no-progress guard
            // → paired tool_result append → schema refresh + compat-only sweep.
            // The streaming-only pending-prose flush above runs first.
            let outcome = await runToolDispatchRound(
                providerCalls: providerCalls,
                iterationRawText: iterAccumulated,
                ctx: ctx,
                surface: surface,
                sessionId: sessionId,
                tools: tools,
                progress: progress,
                conversation: &conversation,
                dispatches: &dispatches,
                activeToolSchemas: &activeToolSchemas,
                providerTools: &providerTools,
                noProgressGuard: &noProgressGuard,
                loopRecoveryReply: &loopRecoveryReply
            )
            if case .stopLoop = outcome { break }
        }

        // Shared exhaustion tail (C2). Streaming also treats a streamed
        // tool-call round as "only a structured tool call", so it passes
        // lastProviderHadToolCalls as the extra signal.
        return await finishExhaustedTurn(
            ctx: ctx,
            lastRawResponse: lastRawResponse,
            lastProtocolViolation: lastProtocolViolation,
            loopRecoveryReply: loopRecoveryReply,
            iterationLimit: iterationLimit,
            dispatches: dispatches,
            startNs: startNs,
            providerCallCount: providerCallCount,
            userMessage: userMessage,
            sessionId: sessionId,
            surface: surface,
            additionalStructuredToolCallSignal: lastProviderHadToolCalls
        )
    }

    // MARK: - Per-iteration dispatch (shared by both loops; U1 step 6)

    /// One provider call, fully resolved for dispatch. Built up-front so
    /// task-group children capture only Sendable value types (plus the
    /// Sendable `tools` / `progress` references) — never the conversation
    /// array or any actor state.
    struct PreparedToolCall: Sendable {
        let pairedId: String
        let internalName: String
        let dispatchInput: [String: JSONValue]
    }

    /// Execute ONE iteration's batch of tool calls and return the
    /// tool_result blocks + dispatch records in ORIGINAL INDEX ORDER.
    ///
    /// This is the single implementation behind both the non-streaming and
    /// streaming loops, so the serial/parallel split cannot drift between
    /// them. Semantics preserved from the serial code, per slot:
    ///   .toolUse progress → dispatch (notice bus + runtime ctx bound) →
    ///   record → .toolResult progress → redact → tool_result block.
    /// For a `.concurrent` group the .toolUse events for the whole group are
    /// emitted first (in index order), children dispatch concurrently
    /// (cap: ParallelToolDispatch.maxConcurrentPerIteration; notices stream
    /// live), then records/.toolResult events/blocks are emitted in index
    /// order after the group completes. Errors never escape a slot: a
    /// throwing tool yields that slot's {"error": ...} result exactly as the
    /// serial path would, and never cancels siblings. Turn cancellation
    /// cancels all in-flight children (structured task group).
    func dispatchIterationCalls(
        providerCalls: [ParsedToolCall],
        pairedIds: [String],
        providerTools: ProviderToolNameMap,
        modelId: String,
        surface: String,
        sessionId: String?,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        let prepared: [PreparedToolCall] = providerCalls.enumerated().compactMap { i, call in
            guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
            let internalName = providerTools.internalName(forProviderName: call.name)
            return PreparedToolCall(
                pairedId: i < pairedIds.count ? pairedIds[i] : call.id,
                internalName: internalName,
                dispatchInput: Self.inputWithSessionIfNeeded(
                    toolName: internalName,
                    input: call.input,
                    sessionId: sessionId
                )
            )
        }
        let groups = ParallelToolDispatch.plan(
            parallelSafe: prepared.map {
                ParallelToolDispatch.isParallelSafe(internalToolName: $0.internalName)
            },
            forceSerial: ParallelToolDispatch.effectiveForceSerial
        )

        var outcomes: [Int: (result: JSONValue, isError: Bool)] = [:]
        var blocks: [LLMContentBlock] = []
        var records: [TurnEngineResult.ToolDispatchRecord] = []

        for group in groups {
            switch group {
            case .sequential(let idx):
                let p = prepared[idx]
                await progress?(.toolUse(name: p.internalName, input: .object(p.dispatchInput)))
                let (result, isError) = await Self.runSingleDispatch(
                    prepared: p, modelId: modelId, surface: surface,
                    personaID: personaID,
                    fluidContextTurn: fluidContextTurn,
                    tools: tools, progress: progress
                )
                let out = await Self.makeSlotOutputs(
                    prepared: p,
                    result: result,
                    isError: isError,
                    sessionId: sessionId
                )
                records.append(out.record)
                await progress?(.toolResult(name: p.internalName, output: result))
                blocks.append(out.block)

            case .concurrent(let indices):
                // .toolUse for the whole group up-front, in index order —
                // keeps the progress stream deterministic while children
                // complete in arbitrary order.
                for idx in indices {
                    let p = prepared[idx]
                    await progress?(.toolUse(name: p.internalName, input: .object(p.dispatchInput)))
                }
                // Window of maxConcurrentPerIteration: refill on completion.
                await withTaskGroup(
                    of: (Int, JSONValue, Bool).self
                ) { taskGroup in
                    var iterator = indices.makeIterator()
                    func addNext() -> Bool {
                        guard let idx = iterator.next() else { return false }
                        let p = prepared[idx]
                        taskGroup.addTask {
                            let (result, isError) = await Self.runSingleDispatch(
                                prepared: p, modelId: modelId, surface: surface,
                                personaID: personaID,
                                fluidContextTurn: fluidContextTurn,
                                tools: tools, progress: progress
                            )
                            return (idx, result, isError)
                        }
                        return true
                    }
                    var started = 0
                    while started < ParallelToolDispatch.maxConcurrentPerIteration, addNext() {
                        started += 1
                    }
                    while let (idx, result, isError) = await taskGroup.next() {
                        outcomes[idx] = (result, isError)
                        _ = addNext()
                    }
                }
                // Reassemble in ORIGINAL index order regardless of
                // completion order — the provider pairs tool_result blocks
                // to tool_use blocks by id AND expects consistent ordering.
                for idx in indices {
                    let outcome = outcomes[idx] ?? (
                        result: .object(["error": .string("parallel dispatch produced no result")]),
                        isError: true
                    )
                    let p = prepared[idx]
                    let out = await Self.makeSlotOutputs(
                        prepared: p,
                        result: outcome.result,
                        isError: outcome.isError,
                        sessionId: sessionId
                    )
                    records.append(out.record)
                    await progress?(.toolResult(name: p.internalName, output: outcome.result))
                    blocks.append(out.block)
                }
            }
        }
        return (blocks, records)
    }

    /// Slot finalization, pure: dispatch record + redacted tool_result
    /// block. (Redact before the provider sees it: persistence and progress
    /// events already redact this surface — this path was the one place raw
    /// secrets shipped out, audit 2026-06-09.) Static-pure rather than a
    /// mutable-capturing local function so Swift 6 region isolation doesn't
    /// flag the capture as a cross-task send.
    nonisolated static func makeSlotOutputs(
        prepared: PreparedToolCall,
        result: JSONValue,
        isError: Bool,
        sessionId: String? = nil
    ) async -> (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock) {
        let record = TurnEngineResult.ToolDispatchRecord(
            id: prepared.pairedId,
            name: prepared.internalName,
            input: prepared.dispatchInput,
            result: result
        )
        let resultStr: String = {
            if case .string(let s) = result { return s }
            return (try? result.serialize(pretty: false)) ?? "null"
        }()
        let redactedResultStr = ChatSecretRedactor.redactText(resultStr)
        let providerResultStr = await ProviderToolResultProjection.project(
            toolName: prepared.internalName,
            content: redactedResultStr,
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId
        )
        let block = LLMContentBlock.toolResult(
            toolUseId: prepared.pairedId, content: providerResultStr, isError: isError
        )
        return (record, block)
    }

    /// The single-dispatch core shared by the serial slot and every
    /// task-group child. Mirrors the original serial body: bind the notice bus
    /// to this turn's progress stream + the live turn model/surface (TaskLocals
    /// — propagate down the dispatch task tree), dispatch, and convert ANY
    /// thrown error into the slot's error-object result (the loop continues;
    /// the model sees the error as feedback).
    ///
    /// Trust loop #3: every dispatch is raced against a
    /// hard deadline (ToolDispatchDeadline) — a wedged tool throws
    /// ToolDispatchTimedOut, which the catch below turns into the same
    /// error-object result as any other tool failure, so a hung turn fails
    /// cleanly instead of freezing forever. An explicit disabled deadline
    /// (deadlineNanos == 0) takes the original un-raced path unchanged. The
    /// deadline task is added INSIDE the TaskLocal withValue scopes so the
    /// dispatch child still inherits the runtime ctx + notice bus.
    nonisolated static func projectedToolDispatchError(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let redacted = ChatSecretRedactor.redactText(raw)
        let home = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSafe = home.isEmpty
            ? redacted
            : redacted.replacingOccurrences(of: home, with: "~")
        return String(pathSafe.prefix(2_000))
    }

    nonisolated static func runSingleDispatch(
        prepared: PreparedToolCall,
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?
    ) async -> (JSONValue, Bool) {
        let deadlineNanos = ToolDispatchDeadline.timeoutNanos(
            toolName: prepared.internalName,
            input: prepared.dispatchInput,
            surface: surface
        )
        do {
            let result = try await FluidContextToolScope.$current.withValue(fluidContextTurn) {
            try await ChatTurnRuntimeContext.$current.withValue(
                .init(model: modelId, surface: surface, personaID: personaID)
            ) {
                try await ToolNoticeBus.$emit.withValue({ kind, text in
                    await progress?(.notice(kind: kind, text: text))
                }) {
                    guard deadlineNanos > 0 else {
                        return try await tools.dispatch(
                            tool: prepared.internalName,
                            input: prepared.dispatchInput,
                            surface: surface
                        )
                    }
                    return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                        group.addTask {
                            try await tools.dispatch(
                                tool: prepared.internalName,
                                input: prepared.dispatchInput,
                                surface: surface
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: deadlineNanos)
                            throw ToolDispatchDeadline.ToolDispatchTimedOut(
                                tool: prepared.internalName,
                                seconds: Double(deadlineNanos) / 1_000_000_000
                            )
                        }
                        guard let first = try await group.next() else {
                            // Unreachable: two tasks were added. Treat an empty
                            // group as a benign null result rather than crash.
                            return .null
                        }
                        group.cancelAll()
                        return first
                    }
                }
            }
            }
            // A nonthrowing transport can still carry a canonical failure
            // envelope (including MCP `isError:true`, wrapped or raw). Keep
            // the provider tool-result bit, persisted progress, and traces on
            // the same shared classification.
            return (result, !ChatToolOutcome.outputLooksSuccessful(result))
        } catch {
            let message = Self.projectedToolDispatchError(error)
            return (.object([
                "status": .string("failed"),
                "error": .string(message),
                "reason": .string(message),
            ]), true)
        }
    }

    private nonisolated static func inputWithSessionIfNeeded(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        ChatToolSessionInjection.apply(toolName: toolName, input: input, sessionId: sessionId)
    }
}

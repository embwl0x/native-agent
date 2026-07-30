import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - AnthropicOAuthDirectAdapter
//
// WAVE 28 (2026-06-01) — Swift mirror of `daemon/providers/anthropic_oauth_direct.py`
// (chat + streaming path only).
//
// WAVE 30 (2026-06-03) — added token refresh. setup_tokens turned out to be
// SHORT-lived in production (the user's chat went silently dead when the JWT
// expired — same root-cause class as the wave-27 OpenAI silent-no-reply
// bug: `.notConfigured` fell through to the api-key adapter which has no
// key, so the chat path threw silently). Refresh now happens automatically:
// the adapter checks `expires_at` on disk, calls Anthropic's OAuth refresh
// endpoint when within 120s of expiry, and persists the rotated tokens.
//
// Endpoint + auth (mirrors `_API_BASE + _MESSAGES_URL` + `_api_headers`):
//   POST https://api.anthropic.com/v1/messages
//   Authorization: Bearer <access_token from anthropic_oauth_direct.json>
//   anthropic-version: 2023-06-01
//   anthropic-beta: claude-code-20250219,oauth-2025-04-20,
//                   fine-grained-tool-streaming-2025-05-14
//   x-app: cli
//   user-agent: claude-cli/1.0.0
//   anthropic-dangerous-direct-browser-access: true
//
// Token storage shape (matches NativeOAuthFlow.persistTokens for anthropic):
//   {
//     "access_token":  "...",
//     "refresh_token": "...",
//     "expires_at":    "2026-06-03T18:23:45Z",   // ISO basic UTC
//     "client_id":     "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
//     ...
//   }
// PKCE-shape fallback (`tokens.access_token`) is still read for tests.
//
// Refresh endpoint + body (mirrors the initial sign-in token endpoint at
// NativeOAuthFlow.swift::ProviderOAuthConfig.anthropic):
//   POST https://platform.claude.com/v1/oauth/token
//   Content-Type: application/json
//   { "grant_type": "refresh_token",
//     "refresh_token": "...",
//     "client_id":     "9d1c250a-..." }
//
// Refresh races: multiple adapter instances (BackgroundLoopsAssembly,
// Missions, ChatOrchestrationClient, etc) each construct a fresh
// AnthropicOAuthDirectAdapter. The refresh_token is single-use, so two
// concurrent instances racing on the same file BURN the next refresh. We
// share an AsyncSerialQueue actor across all instances keyed by the
// resolved auth-file path. Same pattern as the OpenAI adapter (wave 27).

public final class AnthropicOAuthDirectAdapter: LLMAdapter {
    public let providerId: String = "anthropic_oauth_direct"

    public static let productionSession: URLSession = makeProductionSession()

    private let session: URLSession
    private let endpoint: URL
    private let refreshEndpoint: URL
    /// Test-injection override for the auth.json path. Production callers
    /// leave this nil and the resolver below walks the canonical layout.
    private let authPathOverride: URL?
    private let maxTokensOverride: Int?
    private let clientID: String
    /// U1 step 1 — per-call llm.call telemetry writer. Additive; the
    /// override is test-only (points the trace feed at a tmp data root).
    private let telemetry: LLMCallTraceRecorder

    public init(
        session: URLSession = AnthropicOAuthDirectAdapter.productionSession,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        refreshEndpoint: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        authPathOverride: URL? = nil,
        maxTokens: Int? = nil,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.authPathOverride = authPathOverride
        self.maxTokensOverride = maxTokens
        self.clientID = clientID
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    func requestMaxTokens(model: String) -> Int {
        FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: LLMCallContext.reasoningEffort,
            explicitOverride: maxTokensOverride
        )
    }

    // MARK: - Constants

    private static let anthropicVersion = "2023-06-01"
    private static let oauthBetaFeatures = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
    ]
    private static let claudeCLIVersion = "1.0.0"
    /// Anthropic's API gates OAuth-mode on this EXACT string being the first
    /// system block.
    private static let claudeCodeIdentity =
        "You are Claude Code, Anthropic's official CLI for Claude."
    private static let defaultClaudeModel = "claude-opus-4-8"
    /// Refresh proactively when the token has less than this many seconds
    /// of life left. Mirrors OpenAI adapter's 120s buffer.
    static let tokenExpiryBufferSec: TimeInterval = 120

    static func makeProductionSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutValue(
            environment["NATIVE_AGENT_ANTHROPIC_OAUTH_REQUEST_TIMEOUT_SEC"],
            fallback: 240
        )
        cfg.timeoutIntervalForResource = timeoutValue(
            environment["NATIVE_AGENT_ANTHROPIC_OAUTH_RESOURCE_TIMEOUT_SEC"],
            fallback: 600
        )
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }

    private static func timeoutValue(_ raw: String?, fallback: TimeInterval) -> TimeInterval {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = TimeInterval(trimmed), parsed > 0 else { return fallback }
        return parsed
    }

    private static func apiHeaders(accessToken: String) -> [String: String] {
        return [
            "Authorization":      "Bearer \(accessToken)",
            "anthropic-version":  anthropicVersion,
            "anthropic-beta":     oauthBetaFeatures.joined(separator: ","),
            "x-app":              "cli",
            "user-agent":         "claude-cli/\(claudeCLIVersion)",
            "anthropic-dangerous-direct-browser-access": "true",
            "Accept":             "application/json",
            "Content-Type":       "application/json",
        ]
    }

    private static func httpError(status: Int, data: Data, context: String) -> LLMError {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return .invalidResponse(status: status) }
        if let usageNotice = providerUsageNotice(raw) {
            return .providerError(message: usageNotice)
        }
        return .underlying(message: "\(context) status \(status): \(redactedErrorBody(raw))")
    }

    private static func providerUsageNotice(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("out of extra usage")
            || lower.contains("usage is exhausted")
            || lower.contains("usage exhausted")
            || lower.contains("quota exceeded")
        {
            return "Anthropic OAuth usage is exhausted. Add more at claude.ai/settings/usage or switch providers."
        }
        return nil
    }

    private static func redactedErrorBody(_ raw: String) -> String {
        var out = raw
        if let re = try? NSRegularExpression(
            pattern: #"(?i)"(access_token|refresh_token|setup_token|authorization|api_key|token)"\s*:\s*"[^"]+""#
        ) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "\"$1\":\"***\"")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*"#) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "Bearer ***")
        }
        if out.count > 1200 {
            return String(out.prefix(1200)) + "... [truncated]"
        }
        return out
    }

    /// Turn Inspector W2 — fire a `thinking.delta` event onto the in-process
    /// bus (fire-and-forget, drop-on-backpressure, NEVER awaited). Carries the
    /// SUMMARIZED thinking text, SECRET-REDACTED by the shared non-digest
    /// TurnTraceRedactor, then bounded by
    /// the event's own per-leaf cap. `redacted:true` marks a RedactedThinking
    /// block rendered honestly as "[redacted]" (never decoded). Skipped when no
    /// turn is bound. The bus reads surface/sessionId from the ambient
    /// LLMCallContext (bound upstream by the chat engine), so no surface param
    /// is threaded here. signature_delta frames are never surfaced.
    ///
    /// GATED on `InspectorThinkingLane.summarizedThinking` (gpt-5.5 W2 review):
    /// only a request that opted into the lane asked for thinking, so a frame
    /// arriving while the lane is OFF — provider quirk, stub, or future default
    /// change — must NOT put thinking text on the bus the user never opted into.
    static func fireThinkingDeltaEvent(_ text: String, redacted: Bool) {
        guard InspectorThinkingLane.summarizedThinking else { return }
        guard TurnTraceContext.turnId != nil else { return }
        let safe = redacted ? text : TurnTraceRedactor.redactText(text)
        TurnTraceBus.fireFromContext(
            kind: "thinking.delta",
            payload: .object([
                "text": .string(safe),
                "redacted": .bool(redacted),
            ])
        )
    }

    private func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        let host = endpoint.host ?? "api.anthropic.com"
        let nsError = error as NSError
        let timeout = Int(session.configuration.timeoutIntervalForRequest.rounded())
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut:
                return .transient(message: "anthropic_oauth_direct \(operation) timed out after \(timeout)s: \(host)")
            case .cannotConnectToHost:
                return .transient(message: "anthropic_oauth_direct \(operation) cannot connect to \(host) (code=\(nsError.code))")
            case .networkConnectionLost:
                return .transient(message: "anthropic_oauth_direct \(operation) network connection was lost: \(host) (code=\(nsError.code))")
            case .notConnectedToInternet:
                return .transient(message: "anthropic_oauth_direct \(operation) not connected to internet: \(host) (code=\(nsError.code))")
            case .cannotFindHost, .dnsLookupFailed:
                return .transient(message: "anthropic_oauth_direct \(operation) cannot resolve \(host) (code=\(nsError.code))")
            default:
                return .transient(message: "anthropic_oauth_direct \(operation) network error for \(host): \(error) (code=\(nsError.code))")
            }
        }
        return .transient(message: "anthropic_oauth_direct \(operation) network error for \(host): \(error)")
    }

    // MARK: - Shared refresh-actor registry
    //
    // Production has 4+ callsites constructing fresh adapter instances. A
    // PER-INSTANCE actor would let two instances refresh in parallel and
    // rotate the single-use refresh_token twice — the second rotation
    // burns the credential. Share one AsyncSerialQueue per resolved auth
    // file path across the process.

    nonisolated(unsafe) private static var sharedRefreshActors: [String: AsyncSerialQueue] = [:]
    private static let sharedRefreshActorsLock = NSLock()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        sharedRefreshActorsLock.lock()
        defer { sharedRefreshActorsLock.unlock() }
        let key = path.standardizedFileURL.path
        if let existing = sharedRefreshActors[key] { return existing }
        let q = AsyncSerialQueue()
        sharedRefreshActors[key] = q
        return q
    }

    // MARK: - Model coercion

    static func coerceToClaudeModel(_ requested: String?) -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespaces), !r.isEmpty else {
            return defaultClaudeModel
        }
        let lower = r.lowercased()
        if lower.hasPrefix("claude-") { return r }
        if lower.hasPrefix("anthropic/") {
            let suffix = String(r.dropFirst("anthropic/".count))
            if suffix.lowercased().hasPrefix("claude-") { return suffix }
        }
        return defaultClaudeModel
    }

    // MARK: - U1 item 8 (F1 lane (b)) — conversation caching + lever
    //
    // The structured tool loop (ChatOrchestration+ToolLoop.swift) sends an
    // APPEND-ONLY messages array (user → assistant tool_use → user
    // tool_result → repeat; pinned by ToolLoopAppendOnlyQATests). Without a
    // cache_control breakpoint inside `messages`, the cacheable prefix ends
    // at the system/tools blocks — every loop iteration re-pays ALL prior
    // message mass (F1 live measure: 12-18k tokens/iteration; only
    // Anthropic's server-side heuristic auto-caching ever recovered any of
    // it, and F1 showed that heuristic alternates clean/churn). The
    // first implementation moved one explicit breakpoint to the LAST content
    // block of the LAST message. Live clean-install evidence showed that it
    // reused cache within one tool loop but never on the first call of the
    // next turn: the previous request boundary disappeared when the next
    // assistant+user pair was appended. Anthropic's top-level automatic cache
    // field was also live-probed on this OAuth/Claude-Code transport and
    // produced no cache creation. The compatible text lane therefore retains
    // TWO explicit boundaries: the previous request end and the current end.
    //
    // BREAKPOINT BUDGET (Anthropic max 4): text compatibility uses identity +
    // stable-end + previous-message + current-message = 4. Structured native
    // tools retain identity + stable-end + last-tool + current-message = 4.
    // The current message breakpoint takes the slot the F1 lane (a)
    // dynamic-end breakpoint used on
    // tool-capable requests. That trade is strictly better on the messages
    // path: the message-trailing breakpoint's prefix INCLUDES every system
    // block, so the dynamic block is covered from iteration 1's write on —
    // lane (a)'s within-turn benefit is subsumed.
    //
    // CONTRACT (items 8 + 9, made explicit per gpt-5.5 review 2026-06-11):
    // conversation caching ships iff the call is tool-capable OR
    // withinTurnReuse-hinted (MessagesCacheHint, item 9) — AND the last
    // message carries a non-empty content block (trailing-eligible), AND
    // the grown-prompt compat lever is off. Layouts:
    //   tool-capable: identity + stable-end + last-tool + trailing = 4 ≤ 4
    //     (test-pinned in LLMCallTelemetryTests);
    //   no-tools + withinTurnReuse hint (the text-compat loop): identity +
    //     stable-end + previous + current = 4 ≤ 4 after the first request
    //     (test-pinned in
    //     AnthropicStreamMessagesSSETests).
    // No combination of (hint × tools × segmented × compat) can ever emit a
    // 5th breakpoint — whenever the trailing breakpoint ships, the dynamic-
    // end breakpoint is suppressed (`toolCapable && !useConversationCache`), so
    // the budget is closed under the full matrix (test-pinned:
    // makeMessagesRequestBody_breakpointBudgetMatrix_neverExceedsFour).
    // Non-tool messages calls WITHOUT the hint are single-shot per turn (no
    // within-turn reuse): NO trailing breakpoint, request bodies
    // byte-identical to the pre-item-8 shape.
    //
    // STEP-5 INTERACTION (IntraTurnToolResultClearing): the sweep rewrites
    // tool-result bodies OLDER than the keep window (current + 5). The
    // breakpoint always sits on the NEWEST message, which the sweep never
    // touches in the same request; once a body is stubbed its bytes are
    // stable again, so the prefix re-converges and the per-iteration re-pay
    // stays bounded by the keep window. No message COUNT or ORDER changes.
    //
    // ROLLBACK LEVER: env NATIVE_AGENT_GROWN_PROMPT_COMPAT=1 (or
    // true/yes/on) restores the old wire shape — dynamic-end breakpoint on
    // tool-capable requests, NO message breakpoint. Default is the new
    // shape. `compatOverride` is the task-local test hook for the same
    // switch (mirrors ParallelToolDispatch's step-6 lever pattern).
    // Model-visible content is IDENTICAL in both states — the lever moves
    // cache markers only (equivalence test-pinned modulo cache_control).
    // PUBLIC (gpt-5.5 review fix, 2026-06-10): ChatOrchestration's tool
    // loop gates the intra-turn clearing sweep on this same lever —
    // clearing rewrites bytes inside the trailing-message cached prefix
    // and would torch the cache hit from the moment it engages. In the
    // new (default) shape the sweep is OFF and caching carries the cost
    // (0.1x cache-reads strictly beat clearing's uncached savings on
    // every provider with prefix caching). Compat mode restores the old
    // wire layout AND the sweep together.
    public enum GrownPromptCompat {
        static let envVar = "NATIVE_AGENT_GROWN_PROMPT_COMPAT"

        /// Pure, injectable parser for the env flag.
        static func isForced(env: [String: String]) -> Bool {
            guard let raw = env[envVar]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !raw.isEmpty else { return false }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        static let forcedFromEnv = isForced(env: ProcessInfo.processInfo.environment)

        /// Test hook: binds over the env flag for a task tree. Production
        /// never binds it (nil → env flag decides).
        @TaskLocal public static var compatOverride: Bool?

        public static var effective: Bool { compatOverride ?? forcedFromEnv }
    }

    // MARK: - U1 item 9 — within-turn-reuse hint (text-compat messages loop)
    //
    // The Anthropic TEXT-COMPAT chat loop (ChatOrchestrationClient.
    // runTextStreamingCompatibility — the path claude-* models on
    // chat/telegram/ios actually run) sends NO provider tools[] (subscription
    // billing contract), so item 8's `toolCapable` gate would never grant it
    // the trailing MESSAGE breakpoint — yet it is exactly the multi-iteration
    // within-turn-reuse shape that breakpoint exists for. This task-local is
    // the caller's explicit "I will re-send this conversation as a prefix
    // next iteration" signal: the ChatOrchestration streaming engine binds it
    // around its messages-transport construction (same propagation mechanism
    // as LLMCallContext.sessionId — the binding wraps SYNCHRONOUS stream
    // construction; inner adapter Tasks inherit). Unbound (every other
    // caller) → false → request bodies byte-identical to pre-item-9.
    //
    // Budget on the hinted no-tools path: identity + stable-end + trailing
    // message = 3 ≤ 4 (no tools block → no last-tool breakpoint; the dynamic
    // system block is covered by the trailing breakpoint's prefix, so lane
    // (a) stays subsumed exactly as on the tool-capable path).
    public enum MessagesCacheHint {
        @TaskLocal public static var withinTurnReuse: Bool = false
    }

    /// U1 item 9: TRUE when the auth file at `path` carries a usable access
    /// token (expiry ignored — the adapter refreshes inline on use). The
    /// text-compat loop preflights this before choosing the append-only
    /// messages transport: without OAuth credentials the messages path would
    /// fall through to the api-key adapter's NON-streaming streamMessages
    /// default (single-delta flatten) and kill live deltas, while the legacy
    /// prompt transport keeps real SSE through the api-key adapter's
    /// stream(). Fail-closed → caller keeps the legacy wire shape.
    public static func hasUsableOAuthCredentials(at path: URL) -> Bool {
        loadAccessTokenAndExpiry(from: path) != nil
    }

    // MARK: - cache_control body helpers (U1 step 3 + 2b/3b, 2026-06-10)
    //
    // Anthropic prompt caching is a PREFIX match over tools → system →
    // messages. Three ephemeral breakpoints (max 4 allowed):
    //   (a) the LAST tool definition  — caches the whole tools block
    //   (b) the claudeCodeIdentity system block — caches tools + identity
    //   (c) the END of the STABLE system mass:
    //       - with a stable/dynamic split bound via
    //         LLMCallContext.systemSegments (U1 2b/3b), the breakpoint sits
    //         on the stable block (persona+pins) and the dynamic block
    //         (recall+history) follows with NO breakpoint — so the per-turn
    //         churn stops invalidating the persona prefix and stops paying
    //         the 1.25x write premium uncached every turn;
    //       - without segments, the caller-supplied sys string is ONE block
    //         with the breakpoint (byte-identical to the pre-2b/3b shape).
    // Blocks below the model's minimum cacheable prefix silently don't
    // cache (no error) — verified via usage.cache_read_input_tokens.

    // Computed (not stored) — a stored static [String: Any] is rejected as a
    // non-Sendable mutable global under Swift 6 strict concurrency.
    static var ephemeralCacheControl: [String: Any] { ["type": "ephemeral"] }

    /// Mark the current append-only request boundary and, when budget permits,
    /// retain the preceding request boundary. Each loop/turn appends an
    /// assistant response and a user/tool-result message, so the prior request
    /// ended at `count - 3`. Retaining that exact marker lets Anthropic read
    /// the established prefix before creating only the newly appended delta.
    static func addConversationCacheControls(
        _ messages: inout [[String: Any]],
        retainPreviousBoundary: Bool
    ) {
        func mark(_ index: Int) {
            guard messages.indices.contains(index),
                  var content = messages[index]["content"] as? [[String: Any]],
                  var lastBlock = content.last else { return }
            lastBlock["cache_control"] = ephemeralCacheControl
            content[content.count - 1] = lastBlock
            messages[index]["content"] = content
        }
        if retainPreviousBoundary, messages.count >= 3 {
            mark(messages.count - 3)
        }
        if !messages.isEmpty {
            mark(messages.count - 1)
        }
    }

    /// DEBUG-ONLY diagnostic: when NATIVE_AGENT_LLM_BODY_DUMP_DIR is set,
    /// write every outgoing request body to that directory so cache-breakpoint
    /// placement can be inspected offline (U1 finding #1 hunt, 2026-06-10).
    /// Bodies contain persona/conversation content, so this is compiled OUT
    /// of release builds entirely (#if DEBUG) — a stray env var in a
    /// production launch context can never activate it (gpt-5.5 review
    /// blocker, 2026-06-10). The Authorization header is never dumped.
    static func dumpBodyIfEnabled(_ body: [String: Any], call: String) {
        #if DEBUG
        guard let dir = ProcessInfo.processInfo.environment["NATIVE_AGENT_LLM_BODY_DUMP_DIR"],
              !dir.isEmpty else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        // UUID suffix: concurrent same-millisecond dumps must not overwrite
        // each other.
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("\(ts)-\(call)-\(UUID().uuidString.prefix(8)).json")
        if let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: [.atomic])
        }
        #endif
    }

    /// system blocks: identity (+ stable + dynamic | + combined sys).
    ///
    /// `segments` defaults to the request-scoped TaskLocal so every call
    /// path (complete / completeMessages / runStream — all run inside the
    /// task that inherited the loop's binding) picks the split up without
    /// signature churn at the call sites.
    ///
    /// SAFETY GUARD: the split is used ONLY when the segments reassemble
    /// byte-for-byte into `system` (INVARIANT: system == stable + "\n\n" +
    /// dynamic — see TurnContext.systemSegments). Any mismatch — stale
    /// binding, caller-mutated sys — falls back to the combined block, so
    /// model-visible content can never change.
    ///
    /// BYTE FAITHFULNESS (gpt-5.5 review blocker, 2026-06-10): the emitted
    /// stable+dynamic block TEXTS must concatenate byte-for-byte to the
    /// combined `system` string — the API does not guarantee any particular
    /// join between adjacent text blocks, so the "\n\n" separator is carried
    /// as a SUFFIX on the stable block's text (cache-safe: the suffix is
    /// exactly as stable as the block it rides on). The identity block is
    /// different: it has ALWAYS been its own block, never part of the `sys`
    /// string (pre-U1 shape was already [identity][sys]), so it carries no
    /// join contract with the blocks that follow it.
    ///
    /// `toolCapable` (U1 F1 lane (a), step-6 rider, 2026-06-10): on TOOL-
    /// CAPABLE requests with a stable/dynamic split, the dynamic block ALSO
    /// gets a breakpoint — within a multi-iteration tool turn the dynamic
    /// mass (recall+history, built once per turn) is byte-identical across
    /// iterations, so iteration 2..N read it from cache instead of re-paying
    /// ~2k input tokens per iteration (F1 live measurement). Breakpoint
    /// budget: last-tool + identity + stable-end + dynamic-end = 4 ≤ 4.
    /// On NON-tool turns there is exactly ONE call per turn and the dynamic
    /// block churns across turns — a breakpoint there would pay the 1.25x
    /// cache-write premium with ~zero read probability, hence the gate.
    /// (Unsegmented fallback: the combined sys block already carries the
    /// end-of-system breakpoint; nothing extra to add.)
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments? = LLMCallContext.systemSegments,
        toolCapable: Bool = false
    ) -> [[String: Any]] {
        var blocks: [[String: Any]] = [
            [
                "type": "text",
                "text": claudeCodeIdentity,
                "cache_control": ephemeralCacheControl,
            ],
        ]
        guard let sys = system, !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return blocks
        }
        if let seg = segments,
           !seg.stable.isEmpty, !seg.dynamic.isEmpty,
           seg.reassembles(into: sys)
        {
            // Stable block carries the "\n\n" separator as its suffix so
            // stable-block-text + dynamic-block-text == `sys` byte-for-byte.
            blocks.append([
                "type": "text",
                "text": seg.stable + "\n\n",
                "cache_control": ephemeralCacheControl,
            ])
            // Dynamic tail: cache_control ONLY on tool-capable requests
            // (within-turn iteration reads; see toolCapable doc above).
            // Non-tool turns: NO breakpoint — recall+history churn per turn.
            if toolCapable {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                    "cache_control": ephemeralCacheControl,
                ])
            } else {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                ])
            }
        } else {
            blocks.append([
                "type": "text",
                "text": sys,
                "cache_control": ephemeralCacheControl,
            ])
        }
        return blocks
    }

    /// Anthropic Messages-API tools list with a cache_control breakpoint on
    /// the LAST definition. Returns nil for nil/empty input so the no-tools
    /// request body stays byte-identical to the no-tools overload.
    static func makeToolList(_ tools: [LLMToolSchema]?) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return nil }
        var toolList: [[String: Any]] = []
        for t in tools {
            var entry: [String: Any] = [
                "name": t.name,
                "description": t.description,
            ]
            if let schema = try? JSONSerialization.jsonObject(with: t.parametersJSON) {
                entry["input_schema"] = schema
            } else {
                entry["input_schema"] = [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any]
            }
            toolList.append(entry)
        }
        toolList[toolList.count - 1]["cache_control"] = ephemeralCacheControl
        return toolList
    }

    // MARK: - Shared messages-request body builder (U1 items 8 + 9)
    //
    // ONE encoder behind completeMessages AND the streaming runStreamMessages
    // so the wire shape (block encoding, breakpoint layout, lever behavior)
    // cannot drift between the non-streaming and SSE transports. The bodies
    // are test-pinned deep-equal modulo the `stream` key
    // (LLMCallTelemetryTests + AnthropicStreamMessagesSSETests).
    //
    // Reads three task-locals at call time (all inherited through the
    // adapter's inner Task per the LLMCallContext propagation contract):
    //   - LLMCallContext.systemSegments (via makeSystemBlocks' default arg)
    //   - GrownPromptCompat.compatOverride (rollback lever)
    //   - MessagesCacheHint.withinTurnReuse (item 9 — see enum doc above)
    static func makeMessagesRequestBody(
        messages: [LLMMessage],
        system: String?,
        coercedModel: String,
        maxTokens: Int,
        tools: [LLMToolSchema]?,
        stream: Bool
    ) -> [String: Any] {
        // U1 items 8 + 9 — conversation-cache INVARIANT: caching ships iff
        // the call is tool-capable OR withinTurnReuse-
        // hinted (and trailing-eligible, and not compat). Both grantors are
        // legitimate reuse signals: tools[] implies a multi-iteration
        // structured loop (item 8); the hint is the no-tools text-compat
        // loop's explicit "I re-send this conversation as a prefix next
        // iteration" signal (item 9 — see MessagesCacheHint). The current
        // message breakpoint replaces the lane-(a) dynamic-end breakpoint (its prefix
        // covers every system block, so the dynamic block is cached from
        // iteration 1's write on — and the 4-breakpoint budget has no room for
        // both; the `toolCapable && !useConversationCache` arg below is
        // what closes the budget at ≤ 4 across the whole hint × tools ×
        // segmented × compat matrix, test-pinned). The grown-prompt compat
        // lever restores the old layout. Non-tool un-hinted calls keep the
        // pre-item-8 body byte-identical (no trailing breakpoint, no
        // dynamic-end — single-shot turns have no within-turn reuse).
        let toolCapable = !(tools?.isEmpty ?? true)
        // Prove a conversation breakpoint CAN ship before
        // suppressing dynamic-end — an empty messages
        // array (or an empty last content) would otherwise lose BOTH
        // breakpoints silently. Eligibility on the source LLMMessages
        // mirrors the encoder exactly (every content block encodes to
        // one Anthropic block).
        let trailingEligible = !(messages.last?.content.isEmpty ?? true)
        let useConversationCache =
            (toolCapable || MessagesCacheHint.withinTurnReuse)
            && trailingEligible
            && !Self.GrownPromptCompat.effective
        let systemBlocks = Self.makeSystemBlocks(
            system, toolCapable: toolCapable && !useConversationCache
        )

        // Encode each LLMMessage as an Anthropic message with structured
        // content blocks. Text-only messages can use the short `content:
        // "..."` form, but anything with tool_use/tool_result MUST use
        // the array-of-blocks form.
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text(let t):
                    blocks.append(["type": "text", "text": t])
                case .toolUse(let id, let name, let inputJSON):
                    let inputObj: Any = (try? JSONSerialization.jsonObject(with: inputJSON)) ?? [String: Any]()
                    blocks.append([
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": inputObj,
                    ])
                case .toolResult(let toolUseId, let content, let isError):
                    var entry: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                    if isError { entry["is_error"] = true }
                    blocks.append(entry)
                case .image(let mediaType, let base64, _, _):
                    // Native vision — Anthropic Messages API base64 image block.
                    // userWithImages emits image blocks FIRST, then the text
                    // block, so the canonical [image..., text] order is held by
                    // the content array's own order here.
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64,
                        ],
                    ])
                }
            }
            anthropicMessages.append([
                "role": m.role == .user ? "user" : "assistant",
                "content": blocks,
            ])
        }
        if useConversationCache {
            Self.addConversationCacheControls(
                &anthropicMessages,
                // The text lane has one free fourth slot. Structured tools
                // already spend it on the last tool definition.
                retainPreviousBoundary: !toolCapable && MessagesCacheHint.withinTurnReuse
            )
        }
        var body: [String: Any] = [
            "model": coercedModel,
            "max_tokens": maxTokens,
            "messages": anthropicMessages,
            "system": systemBlocks,
        ]
        if stream {
            body["stream"] = true
        }
        if let toolList = Self.makeToolList(tools) {
            body["tools"] = toolList
        }
        // Turn Inspector W2 — GATED summarized-thinking lane. The `thinking`
        // param is part of the request BODY, so adding it CHANGES the bytes on
        // the wire (and the U1 cache prefix). It is therefore strictly gated on
        // the per-surface opt-in task-local `InspectorThinkingLane.summarized-
        // Thinking`, which is FALSE unless the Mac chat surface explicitly binds
        // it TRUE (read here at call time, same as the other body task-locals).
        // UNBOUND (the default everywhere) → the key is NOT added → the body is
        // BYTE-IDENTICAL to pre-W2. Display "summarized" yields SUMMARIZED
        // thinking blocks (Opus 4.7/4.8 omit raw CoT); the SSE parser renders
        // thinking_delta onto the bus and redacted_thinking as "[redacted]" —
        // blocks and signatures are NEVER mutated.
        if InspectorThinkingLane.summarizedThinking {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel)
        return body
    }

    // MARK: - LLMAdapter conformance

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    /// Structured multi-turn variant. Encodes the LLMMessage array into
    /// Anthropic Messages-API content blocks (text / tool_use / tool_result)
    /// so the model sees its prior tool calls AND their results in the
    /// canonical wire shape. Without this the tool loop never converges —
    /// see the conversation-shape comment on LLMMessage in LLMClient.swift.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let coercedModel = Self.coerceToClaudeModel(model)
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
            } catch is CancellationError { throw CancellationError() }
            catch let err as LLMError { throw err }
            catch { throw LLMError.notConfigured(provider: "anthropic_oauth_direct") }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }

            // Body shape (breakpoint layout, lever behavior, encoding) lives
            // in the shared builder — one encoder for the non-streaming and
            // SSE messages transports (U1 item 9).
            let body = Self.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: coercedModel,
                maxTokens: requestMaxTokens(model: coercedModel),
                tools: tools,
                stream: false
            )
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }
            Self.dumpBodyIfEnabled(body, call: "completeMessages")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "completeMessages"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if attempt == 0 { continue }
                // A3.1: refresh already ran (attempt 1) and the new token is
                // still rejected → the credential is genuinely revoked, not
                // "unconfigured". Carry the provider body so the cause reads.
                throw LLMError.authRejected(
                    provider: "anthropic_oauth_direct", detail: providerErrorDetail(data))
            }
            if status == 429 {
                throw LLMError.rateLimited(
                    message: String(data: data, encoding: .utf8) ?? "rate limited",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                // Wave-2 5xx unification (F3-M3): a streaming/HTTP 5xx from
                // Agent's PRIMARY provider is retryable, not terminal. `.transient`
                // is what the surface retry ladders match on; `.underlying` was
                // terminally failing turns that GPT/Moonshot/xAI would have
                // replayed. Body text preserved for diagnosis.
                throw LLMError.transient(message: String(data: data, encoding: .utf8) ?? "5xx")
            }
            guard (200..<300).contains(status) else {
                throw Self.httpError(status: status, data: data, context: "anthropic oauth")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else {
                throw LLMError.invalidResponse(status: status)
            }
            // Walk content blocks: text → append; tool_use → emit
            // `<tool_use id="..." name="...">{json}</tool_use>` markers the
            // ToolCallParser understands. ID is now included so the tool
            // loop can pair the result back to the call.
            var pieces: [String] = []
            for block in content {
                guard let btype = block["type"] as? String else { continue }
                if btype == "text", let t = block["text"] as? String {
                    pieces.append(t)
                } else if btype == "tool_use" {
                    let id = (block["id"] as? String) ?? ""
                    let name = (block["name"] as? String) ?? ""
                    let input = block["input"] ?? [String: Any]()
                    let bodyData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                    let bodyStr = String(data: bodyData, encoding: .utf8) ?? "{}"
                    pieces.append("<tool_use id=\"\(id)\" name=\"\(name)\">\(bodyStr)</tool_use>")
                }
            }
            if pieces.isEmpty {
                throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                    providerID: providerId,
                    stopReason: obj["stop_reason"] as? String,
                    expectedOutput: "answer text or tool call"
                )
            }
            // U1 step 1: capture provider usage (incl. cache counters) into
            // the llm.call trace feed. Non-fatal; numbers only. Recorded
            // AFTER the pieces validation so a 200 with unsupported/empty
            // content throws WITHOUT leaving a misleading "ok" row
            // (gpt-5.5 review blocker, 2026-06-10).
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: coercedModel,
                streaming: false,
                usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: durationMs
            )
            return pieces.joined(separator: "\n")
        }
        throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let coercedModel = Self.coerceToClaudeModel(model)
        // Two-attempt loop mirrors the OpenAI adapter: refresh inline on a
        // 401 once. Avoids the wave-27 double-rotate bug by NOT also
        // refreshing inline on the first 401 — just loops with
        // forceRefresh=true on the second pass.
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LLMError {
                throw err
            } catch {
                throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
            }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }

            // toolCapable mirrors makeToolList's non-empty rule so the
            // dynamic-end breakpoint appears exactly when a tools block does.
            let systemBlocks = Self.makeSystemBlocks(
                system, toolCapable: !(tools?.isEmpty ?? true)
            )
            var body: [String: Any] = [
                "model": coercedModel,
                "max_tokens": requestMaxTokens(model: coercedModel),
                "messages": [["role": "user", "content": prompt]],
                "system": systemBlocks,
            ]
            // Anthropic Messages-API tools field. Only add when non-empty so a
            // nil/empty tools arg produces a byte-identical request body to
            // the no-tools path.
            if let toolList = Self.makeToolList(tools) {
                body["tools"] = toolList
            }
            FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel)
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }
            Self.dumpBodyIfEnabled(body, call: "complete")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "complete"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if attempt == 0 { continue }
                // A3.1: refresh already ran (attempt 1) and the new access
                // token is still rejected → genuinely revoked. authRejected
                // carries the provider body + reconnect guidance instead of
                // the misleading "not configured" (there is no api-key swap —
                // OAuth-direct errors surface directly, WAVE 28).
                throw LLMError.authRejected(
                    provider: "anthropic_oauth_direct", detail: providerErrorDetail(data))
            }
            if status == 429 {
                let msg = String(data: data, encoding: .utf8) ?? "rate limited"
                throw LLMError.rateLimited(
                    message: msg, retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                // Wave-2 5xx unification (F3-M3): retryable, not terminal — see
                // the completeMessages site above. Body preserved for diagnosis.
                let body = String(data: data, encoding: .utf8) ?? "5xx"
                throw LLMError.transient(message: body)
            }
            guard (200..<300).contains(status) else {
                throw Self.httpError(status: status, data: data, context: "anthropic oauth")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else {
                throw LLMError.invalidResponse(status: status)
            }
            // HOTFIX 2026-06-03 tool-wire: walk EVERY content block (was
            // first["text"] only). For text blocks, append `text`. For
            // tool_use blocks, emit
            // `<tool_use id="..." name="X">{json input}</tool_use>`
            // markers that ToolCallParser.parseAnthropic in
            // ChatOrchestration+ToolLoop.swift parses. The `id` field carries
            // the Anthropic-issued toolu_... call id so the tool loop can
            // echo it back as the matching tool_result block's tool_use_id.
            var pieces: [String] = []
            for block in content {
                guard let btype = block["type"] as? String else { continue }
                if btype == "text", let t = block["text"] as? String {
                    pieces.append(t)
                } else if btype == "tool_use" {
                    let id = (block["id"] as? String) ?? ""
                    let name = (block["name"] as? String) ?? ""
                    let input = block["input"] ?? [String: Any]()
                    let bodyData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                    let body = String(data: bodyData, encoding: .utf8) ?? "{}"
                    pieces.append("<tool_use id=\"\(id)\" name=\"\(name)\">\(body)</tool_use>")
                }
                // Other block types (thinking, redacted, etc.) intentionally
                // dropped — they're internal model artifacts the chat path
                // shouldn't surface.
            }
            if pieces.isEmpty {
                throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                    providerID: providerId,
                    stopReason: obj["stop_reason"] as? String,
                    expectedOutput: "answer text or tool call"
                )
            }
            // U1 step 1: token/cache usage telemetry. Recorded AFTER the
            // pieces validation so a 200 with unsupported/empty content
            // throws WITHOUT leaving a misleading "ok" row (gpt-5.5 review
            // blocker, 2026-06-10).
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: coercedModel,
                streaming: false,
                usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: durationMs
            )
            return pieces.joined(separator: "\n")
        }
        throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let coercedModel = Self.coerceToClaudeModel(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        prompt: prompt,
                        system: system,
                        model: coercedModel,
                        continuation: continuation
                    )
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        prompt: String,
        system: String?,
        model: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(forceRefresh: attempt == 1)

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let systemBlocks = Self.makeSystemBlocks(system)
            var body: [String: Any] = [
                "model": model,
                "max_tokens": requestMaxTokens(model: model),
                "stream": true,
                "messages": [["role": "user", "content": prompt]],
                "system": systemBlocks,
            ]
            FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            Self.dumpBodyIfEnabled(body, call: "runStream")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "stream"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            if status == 429 {
                // A3.4: honor Retry-After (header available pre-drain).
                throw LLMError.rateLimited(
                    message: "rate limited",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if !(200..<300).contains(status) {
                var body = Data()
                for try await byte in bytes {
                    if body.count < 4096 {
                        body.append(byte)
                    }
                }
                // A3.1: refresh already ran (attempt 1) and the token is still
                // rejected → genuinely revoked, not "unconfigured".
                if status == 401 {
                    throw LLMError.authRejected(
                        provider: "anthropic_oauth_direct", detail: providerErrorDetail(body))
                }
                throw Self.httpError(status: status, data: body, context: "anthropic oauth")
            }

            // U1 step 1 — streaming telemetry. Anthropic splits usage across
            // message_start (input + cache counters) and message_delta
            // (output_tokens); TTFT is stamped at the FIRST yielded text
            // delta; the row is recorded on message_stop.
            var usage = LLMUsage()
            var ttftMs: Int?
            var yieldedAnyText = false
            var lastStopReason: String?
            // R15: SSEEventStream owns framing; protocol semantics stay here.
            for try await sse in SSEEventStream(bytes) {
                try Task.checkCancellation()
                let payload = sse.data
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let payloadType = obj["type"] as? String ?? ""
                let eventName = sse.event ?? ""
                let effectiveEvent = eventName.isEmpty ? payloadType : eventName
                switch effectiveEvent {
                case "error":
                    let errObj = obj["error"] as? [String: Any]
                    let message = (errObj?["message"] as? String)
                        ?? (errObj?["type"] as? String)
                        ?? "unknown error"
                    throw LLMError.providerError(message: "Anthropic OAuth: \(message)")
                case "message_start":
                    let msg = obj["message"] as? [String: Any]
                    usage.merge(LLMUsage.fromAnthropic(msg?["usage"] as? [String: Any]))
                case "message_delta":
                    usage.merge(LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]))
                    if let delta = obj["delta"] as? [String: Any],
                       let stop = delta["stop_reason"] as? String {
                        lastStopReason = stop
                    }
                case "message_stop":
                    let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        provider: providerId,
                        model: model,
                        streaming: true,
                        usage: usage.isEmpty ? nil : usage,
                        ttftMs: ttftMs,
                        durationMs: durationMs
                    )
                    if !yieldedAnyText {
                        throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                            providerID: providerId,
                            stopReason: lastStopReason,
                            expectedOutput: "answer text"
                        )
                    }
                    continuation.finish()
                    return
                case "content_block_delta":
                    guard let delta = obj["delta"] as? [String: Any],
                          (delta["type"] as? String) == "text_delta",
                          let text = delta["text"] as? String,
                          !text.isEmpty
                    else { continue }
                    if ttftMs == nil {
                        ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    }
                    yieldedAnyText = true
                    continuation.yield(text)
                default:
                    continue
                }
            }
            throw LLMError.streamTruncated(
                message: "Anthropic OAuth stream ended without message_stop"
            )
        }
    }

    // MARK: - U1 item 9 — real SSE over messages-shaped bodies
    //
    // The LLMAdapter default `streamMessages` falls back to NON-streaming
    // completeMessages and yields the reply as one delta — on the Anthropic
    // text-compat chat path that would kill live deltas in the Mac UI. This
    // override streams the SAME wire body completeMessages sends (shared
    // builder above, + "stream": true) through the SAME SSE event protocol
    // runStream parses, extended with the structured tool_use block events
    // (content_block_start → input_json_delta accumulation →
    // content_block_stop → one .toolCall) so the structured streaming tool
    // loop gets live tool-call events too. Error mapping mirrors stream():
    // .notConfigured propagates BEFORE any yield so SwiftNativeLLMClient's
    // api-key fallback chain still engages.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let coercedModel = Self.coerceToClaudeModel(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStreamMessages(
                        messages: messages,
                        system: system,
                        model: coercedModel,
                        tools: tools,
                        continuation: continuation
                    )
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(forceRefresh: attempt == 1)

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let body = Self.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: model,
                maxTokens: requestMaxTokens(model: model),
                tools: tools,
                stream: true
            )
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            Self.dumpBodyIfEnabled(body, call: "streamMessages")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            if status == 429 {
                // A3.4: honor Retry-After (header available pre-drain).
                throw LLMError.rateLimited(
                    message: "rate limited",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if !(200..<300).contains(status) {
                var body = Data()
                for try await byte in bytes {
                    if body.count < 4096 {
                        body.append(byte)
                    }
                }
                // A3.1: refresh already ran (attempt 1) and the token is still
                // rejected → genuinely revoked, not "unconfigured".
                if status == 401 {
                    throw LLMError.authRejected(
                        provider: "anthropic_oauth_direct", detail: providerErrorDetail(body))
                }
                throw Self.httpError(status: status, data: body, context: "anthropic oauth")
            }

            // Telemetry mirrors runStream: usage split across message_start
            // (input + cache counters) and message_delta (output_tokens);
            // row recorded on message_stop. TTFT stamps at the FIRST
            // MODEL-OUTPUT FRAME — first text delta, tool_use
            // content_block_start, or first input_json_delta, whichever
            // arrives first — matching the OpenAI OAuth structured parser's
            // convention exactly (it stamps at output_item.added /
            // function_call_arguments.delta, NOT at output_item.done).
            // Stamping only at content_block_stop (after the whole argument
            // stream) read materially too high for tool-call-first
            // responses (gpt-5.5 review NEEDS_FIX, 2026-06-11).
            var usage = LLMUsage()
            var ttftMs: Int?
            var yieldedSemanticOutput = false
            var lastStopReason: String?
            // In-flight tool_use block being assembled from
            // input_json_delta frames (fine-grained-tool-streaming beta is
            // already in the request headers).
            var openToolId: String?
            var openToolName: String?
            var openToolJSON = ""
            // Mid-stream transport errors (resource timeout, connection
            // lost, ...) thrown by the byte stream must route through the SAME
            // transientNetworkError mapping the initial session.bytes(for:)
            // connect uses — without this wrapper they fell through to
            // streamMessages' generic catch and surfaced as .underlying,
            // so mid-stream URLError.timedOut never classified transient
            // (gpt-5.5 review NEEDS_FIX, 2026-06-11). Intentional LLMErrors
            // from the parser (providerError, httpError, streamTruncated)
            // and cancellation re-throw untouched.
            do {
                // R15: SSEEventStream owns framing; protocol semantics stay here.
                for try await sse in SSEEventStream(bytes) {
                    try Task.checkCancellation()
                    let payload = sse.data
                    if payload.isEmpty || payload == "[DONE]" { continue }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let payloadType = obj["type"] as? String ?? ""
                    // The data JSON's own `type` is authoritative per Anthropic's
                    // streaming protocol; let it WIN over the `event:` name (a
                    // compliant producer MAY omit `event:` and send data-only
                    // frames). Fall back to the event name only when the payload
                    // omits a type (audit #15 — the decoder resets the name per
                    // event, so the old stale-sticky-name mis-route is gone).
                    let effectiveEvent = payloadType.isEmpty ? (sse.event ?? "") : payloadType
                    switch effectiveEvent {
                    case "error":
                        let errObj = obj["error"] as? [String: Any]
                        let message = (errObj?["message"] as? String)
                            ?? (errObj?["type"] as? String)
                            ?? "unknown error"
                        throw LLMError.providerError(message: "Anthropic OAuth: \(message)")
                    case "message_start":
                        let msg = obj["message"] as? [String: Any]
                        usage.merge(LLMUsage.fromAnthropic(msg?["usage"] as? [String: Any]))
                    case "message_delta":
                        usage.merge(LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]))
                        if let delta = obj["delta"] as? [String: Any],
                           let stop = delta["stop_reason"] as? String {
                            lastStopReason = stop
                        }
                    case "message_stop":
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await telemetry.record(
                            provider: providerId,
                            model: model,
                            streaming: true,
                            usage: usage.isEmpty ? nil : usage,
                            ttftMs: ttftMs,
                            durationMs: durationMs
                        )
                        if !yieldedSemanticOutput {
                            throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                                providerID: providerId,
                                stopReason: lastStopReason,
                                expectedOutput: "answer text or tool call"
                            )
                        }
                        continuation.finish()
                        return
                    case "content_block_start":
                        let blockObj = obj["content_block"] as? [String: Any]
                        // Turn Inspector W2 — thinking lane: a redacted thinking
                        // block is rendered HONESTLY as "[redacted]" onto the
                        // bus (never decoded, never mutated). Bus-only — it does
                        // NOT enter the text stream and does NOT change tool/text
                        // handling below.
                        if (blockObj?["type"] as? String) == "redacted_thinking" {
                            Self.fireThinkingDeltaEvent("[redacted]", redacted: true)
                            continue
                        }
                        guard let blockObj,
                              (blockObj["type"] as? String) == "tool_use"
                        else { continue }
                        // First model-output frame for a tool-call-first
                        // response — stamp TTFT here, not at content_block_stop
                        // (parity with the OpenAI parser's output_item.added
                        // stamp; gpt-5.5 review NEEDS_FIX, 2026-06-11).
                        if ttftMs == nil {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        openToolId = (blockObj["id"] as? String) ?? ""
                        openToolName = (blockObj["name"] as? String) ?? ""
                        openToolJSON = ""
                    case "content_block_delta":
                        guard let delta = obj["delta"] as? [String: Any] else { continue }
                        switch delta["type"] as? String {
                        case "text_delta":
                            guard let text = delta["text"] as? String, !text.isEmpty else { continue }
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                            yieldedSemanticOutput = true
                            continuation.yield(.textDelta(text))
                        case "thinking_delta":
                            // Turn Inspector W2 — summarized-thinking lane.
                            // Fire the thinking text onto the bus (redacted +
                            // bounded). Bus-only: it does NOT yield into the
                            // text stream (thinking is NOT the assistant reply)
                            // and does NOT stamp TTFT (TTFT marks the first
                            // user-visible reply token). signature_delta frames
                            // are intentionally IGNORED — signatures are never
                            // surfaced or mutated.
                            if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                                Self.fireThinkingDeltaEvent(thinking, redacted: false)
                            }
                            // Liveness (audit #4, 2026-06-14): thinking is real
                            // model output but NOT user-visible reply text, so it
                            // isn't yielded as content. Without a yield here,
                            // ProviderStreamGuard's idle clock (which wraps this
                            // adapter and only advances on yield) starves during a
                            // long reasoning phase and KILLS a perfectly healthy
                            // turn. Yield a `.keepAlive` to reset the guard's
                            // activity clock — a dedicated no-content signal that
                            // consumers IGNORE, so (unlike the prior
                            // `.textDelta("")`) no empty delta leaks into the
                            // assistant reply or any consumer's token handling.
                            continuation.yield(.keepAlive)
                            continue
                        case "input_json_delta":
                            // Argument deltas are model output even if the
                            // tool_use block_start frame wasn't recognized —
                            // stamp unconditionally (parity with the OpenAI
                            // parser's function_call_arguments.delta stamp).
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                            openToolJSON += (delta["partial_json"] as? String) ?? ""
                            // Liveness (audit #4): tool-argument deltas are model
                            // output but aren't yielded as content, so reset the
                            // guard's idle clock during a long tool-arg
                            // accumulation (same rationale as thinking_delta) via
                            // the no-content `.keepAlive` signal.
                            continuation.yield(.keepAlive)
                        default:
                            continue
                        }
                    case "content_block_stop":
                        guard let name = openToolName else { continue }
                        let trimmedJSON = openToolJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                        let inputJSON = trimmedJSON.isEmpty ? Data("{}".utf8) : Data(trimmedJSON.utf8)
                        // Idempotent last-resort stamp (mirrors the OpenAI
                        // parser's yieldToolCall stamp) — the block-start /
                        // first-argument-delta stamps above win in practice.
                        if ttftMs == nil {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        continuation.yield(.toolCall(LLMStreamToolCall(
                            id: openToolId ?? "",
                            name: name,
                            inputJSON: inputJSON
                        )))
                        yieldedSemanticOutput = true
                        openToolId = nil
                        openToolName = nil
                        openToolJSON = ""
                    default:
                        continue
                    }
                }
            } catch let err as LLMError {
                throw err
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
            }
            throw LLMError.streamTruncated(
                message: "Anthropic OAuth streamMessages ended without message_stop"
            )
        }
    }

    // MARK: - Auth file resolution + token load

    func resolveAuthPath() -> URL {
        if let override = authPathOverride { return override }
        return PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Return a fresh access token, refreshing through the shared serial
    /// actor if the on-disk `expires_at` is within
    /// `tokenExpiryBufferSec` of now (or in the past), or if forceRefresh
    /// is set. Mirrors OpenAIOAuthDirectAdapter.ensureFreshAccessToken.
    func ensureFreshAccessToken(forceRefresh: Bool = false) async throws -> String {
        let path = resolveAuthPath()
        // Fast path — no refresh needed.
        if !forceRefresh, let (token, exp) = Self.loadAccessTokenAndExpiry(from: path) {
            if let exp = exp {
                if exp.timeIntervalSinceNow > Self.tokenExpiryBufferSec {
                    return token
                }
                // Else fall through to refresh.
            } else {
                // No expires_at on disk: long-lived setup_token shape.
                // Don't speculatively refresh — return as-is. The 401 retry
                // path handles a stale token.
                return token
            }
        }
        // Slow path — serialize.
        let actor = Self.sharedRefreshActor(for: path)
        return try await actor.run { [self] in
            // Re-read inside the critical section in case another waiter
            // already refreshed.
            if !forceRefresh, let (token, exp) = Self.loadAccessTokenAndExpiry(from: path) {
                if let exp = exp, exp.timeIntervalSinceNow > Self.tokenExpiryBufferSec {
                    return token
                }
                if exp == nil { return token }
            }
            return try await self.refreshTokens()
        }
    }

    /// Read `(access_token, expires_at)` from the JSON. Returns nil if the
    /// file is missing/unparseable or has no token. `expires_at` is
    /// optional — long-lived setup_tokens omit it.
    static func loadAccessTokenAndExpiry(from path: URL) -> (String, Date?)? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let access: String? = (obj["access_token"] as? String)
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["access_token"] as? String }
        guard let token = access, !token.isEmpty else { return nil }
        let expRaw: Any? = obj["expires_at"]
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["expires_at"] }
        let exp = expRaw.flatMap(parseExpiresAt)
        return (token, exp)
    }

    /// Accept ISO basic ("2026-06-03T18:23:45Z"), full ISO with fractional
    /// seconds, or an integer/double unix timestamp.
    static func parseExpiresAt(_ raw: Any) -> Date? {
        if let s = raw as? String {
            let basic = DateFormatter()
            basic.calendar = Calendar(identifier: .iso8601)
            basic.locale = Locale(identifier: "en_US_POSIX")
            basic.timeZone = TimeZone(secondsFromGMT: 0)
            basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            if let d = basic.date(from: s) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
            return nil
        }
        if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
        return nil
    }

    /// Instance shim used by older call paths / tests.
    private func loadAccessToken() throws -> String {
        try Self.loadAccessToken(from: resolveAuthPath())
    }

    static func loadAccessToken(from path: URL) throws -> String {
        guard let (token, _) = loadAccessTokenAndExpiry(from: path) else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        return token
    }

    // MARK: - Token refresh

    /// POST to the OAuth refresh endpoint, persist the rotated tokens
    /// (atomically, 0600), return the new access token. On non-2xx the
    /// caller sees `.notConfigured` — the api-key adapter chain will then
    /// take over (and likely also throw, but with the right error shape).
    @discardableResult
    func refreshTokens() async throws -> String {
        let path = resolveAuthPath()
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        let refresh: String? = (obj["refresh_token"] as? String)
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["refresh_token"] as? String }
        guard let refreshToken = refresh, !refreshToken.isEmpty else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }

        let body: [String: Any] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]
        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (rdata, response): (Data, URLResponse)
        do {
            (rdata, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // A3.5: a 429/5xx during refresh is a provider-side hiccup, NOT a
            // dead token — surface transient so the session survives without a
            // needless "reconnect" prompt (the misreported-as-revoked bug).
            if status == 429 || (500..<600).contains(status) {
                throw LLMError.transient(
                    message: "anthropic_oauth_direct refresh HTTP \(status) (temporary)")
            }
            // A3.1/A3.5: 401/403/400(invalid_grant) = the refresh token itself
            // was rejected → the credential is genuinely revoked. authRejected
            // carries the reconnect guidance + provider body, instead of the
            // misleading "not configured" (a stranger's revoked token used to
            // read as if they'd never signed in).
            throw LLMError.authRejected(
                provider: "anthropic_oauth_direct", detail: providerErrorDetail(rdata))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any] else {
            throw LLMError.underlying(message: "anthropic refresh: unparseable response")
        }

        // Merge: keep client_id / scope / token_type / user_info; replace
        // access_token, refresh_token (if rotated), recompute expires_at.
        var merged = obj
        if let access = payload["access_token"] as? String, !access.isEmpty {
            merged["access_token"] = access
        }
        if let newRefresh = payload["refresh_token"] as? String, !newRefresh.isEmpty {
            merged["refresh_token"] = newRefresh
        }
        // expires_in is seconds-from-now. Compute an absolute timestamp.
        let expiresIn: Int = {
            if let i = payload["expires_in"] as? Int { return i }
            if let d = payload["expires_in"] as? Double { return Int(d) }
            return 3600
        }()
        let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        merged["expires_at"] = f.string(from: exp)

        do {
            try saveAuthBlob(merged, to: path)
        } catch {
            // Single-use refresh_token already rotated server-side — a
            // swallowed persist failure burns the on-disk credential and
            // surfaces later as a mystery sign-out (audit 2026-06-09).
            FileHandle.standardError.write(Data(
                "AnthropicOAuthDirectAdapter: PERSIST FAILED after token rotation — on-disk refresh_token is now stale: \(error)\n".utf8
            ))
            throw LLMError.underlying(
                message: "anthropic oauth: token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required"
            )
        }

        guard let newAccess = merged["access_token"] as? String, !newAccess.isEmpty else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        return newAccess
    }

    /// Atomic 0600 write. Same pattern as NativeOAuthFlow.writeJSONObject.
    private func saveAuthBlob(_ blob: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: blob,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = path.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path.path
        )
    }
}

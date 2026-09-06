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
//   user-agent: claude-cli/2.1.257
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
// Executions, ChatOrchestrationClient, etc) each construct a fresh
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
    /// Rides ONLY on requests that actually carry a `clear_at` message.
    static let midConversationSystemClearAtBeta =
        "mid-conversation-system-clear-at-2026-08-21"

    /// ONE beta-assembly rule for every Anthropic transport (OAuth headers
    /// below, and both api-key lanes, which otherwise send no
    /// `anthropic-beta` header at all): the clear_at beta is present IFF a
    /// message in THIS request carries the flag. A lane that emitted
    /// `clear_at` in the body without this header would 400.
    static func clearAtBeta(for messages: [LLMMessage]) -> String? {
        messages.contains { $0.turnScopedClearAtNextUserMessage }
            ? midConversationSystemClearAtBeta
            : nil
    }

    /// Rides ONLY on requests that actually carry a `tool_addition` /
    /// `tool_removal` block.
    static let midConversationToolChangesBeta =
        "mid-conversation-tool-changes-2026-07-01"

    /// Same rule as `clearAtBeta`, for the tool-change blocks: present IFF a
    /// message in THIS request carries one. A body with tool-change blocks and
    /// no header is a 400; a header with no blocks would opt every ordinary
    /// request into a beta it does not use.
    static func toolChangeBeta(for messages: [LLMMessage]) -> String? {
        messages.contains { !$0.toolChanges.isEmpty }
            ? midConversationToolChangesBeta
            : nil
    }

    /// The full comma-joined `anthropic-beta` value the MID-CONVERSATION
    /// features need for this request, or nil when it needs none. One
    /// assembly rule for every Anthropic transport: both api-key lanes send
    /// this header ONLY when it is non-nil, so a request that uses neither
    /// feature stays byte-identical to the pre-2026-09 wire.
    static func midConversationBetas(for messages: [LLMMessage]) -> String? {
        let betas = [clearAtBeta(for: messages), toolChangeBeta(for: messages)]
            .compactMap { $0 }
        return betas.isEmpty ? nil : betas.joined(separator: ",")
    }
    // Anthropic gates newer models (Fable 5.1: "version 2.1.251 or newer is
    // required", error_code claude_code_version_too_old) on this version. Keep it
    // at the Claude Code release actually installed on this Mac.
    private static let claudeCLIVersion = "2.1.257"
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

    /// Per-request header assembly. The STATIC beta list is unchanged; the
    /// mid-conversation-system clear_at beta is added ONLY when a message in
    /// THIS request actually carries the flag, so every existing request stays
    /// byte-identical on the wire.
    ///
    /// `model` is accepted so the call site reads as a per-request tuple and a
    /// future model-conditional beta has a home. The capability gate itself
    /// (`supportsMidConversationSystemClearAt`) is enforced UPSTREAM, where the
    /// flag is set: an adapter that silently dropped the beta while the body
    /// still carried `clear_at` would turn a builder bug into a 400.
    static func apiHeaders(
        accessToken: String,
        model: String? = nil,
        messages: [LLMMessage] = []
    ) -> [String: String] {
        var betas = oauthBetaFeatures
        if let midConversation = midConversationBetas(for: messages) {
            betas.append(midConversation)
        }
        return [
            "Authorization":      "Bearer \(accessToken)",
            "anthropic-version":  anthropicVersion,
            "anthropic-beta":     betas.joined(separator: ","),
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

    /// Coerce a requested model id onto the Claude wire id this adapter can
    /// actually serve.
    ///
    /// NORTHSTAR clause 2 (fail loud, no silent substitution): the ONLY
    /// rewrites are enumerated ones — an absent/empty request takes the
    /// adapter default, and an `anthropic/claude-*` namespaced id has its
    /// namespace stripped. Anything else (`llama-3`, `deepseek-chat`, `o3`,
    /// a bare `gpt-*` misrouted onto this adapter) used to fall through to
    /// `defaultClaudeModel`, so User's pick was silently replaced by
    /// claude-opus-4-8 and the call was billed against a model he never
    /// chose. It now throws `modelUnavailable` naming the offending id.
    static func coerceToClaudeModel(_ requested: String?) throws -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return defaultClaudeModel
        }
        let lower = r.lowercased()
        if lower.hasPrefix("claude-") { return r }
        if lower.hasPrefix("anthropic/") {
            let suffix = String(r.dropFirst("anthropic/".count))
            if suffix.lowercased().hasPrefix("claude-") { return suffix }
        }
        throw LLMError.modelUnavailable(provider: "anthropic_oauth_direct", model: r)
    }

    /// The requested id when an enumerated remap actually rewrote it, else
    /// nil. Threaded onto the `llm.call` telemetry row as `substitutedFrom`
    /// so a surviving remap leaves a trace instead of being invisible.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
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

    /// `cache_control` with an explicit TTL. `nil` ttl → the plain 5-minute
    /// ephemeral dict, BYTE-IDENTICAL to `ephemeralCacheControl` (the `ttl`
    /// key is absent, not `"5m"`, so no legacy body changes). `"1h"` is the
    /// GA extended TTL — no beta header required.
    static func ephemeralCacheControl(ttl: String?) -> [String: Any] {
        guard let ttl, !ttl.isEmpty else { return ephemeralCacheControl }
        return ["type": "ephemeral", "ttl": ttl]
    }

    // MESSAGE-ORDER CONTRACT (live 400, 2026-09-01): a mid-conversation
    // system message must IMMEDIATELY FOLLOW a user turn and either end the
    // array or precede an assistant turn. The seeded v2 shape is therefore
    //     [ history… , assistant(N-1), user(N), system(volatile) ]
    // with the system message LAST, and within-turn rounds append AFTER it
    // (assistant tool_use, user tool_result, …). The three index helpers
    // below all read that shape; none of them may ever return a `.system`
    // index, because a system message must never carry cache_control.

    /// The CURRENT TURN's user message.
    ///
    /// AUTHORITATIVE SOURCE: `ConversationPrefixBoundary.currentUserIndex`,
    /// bound per turn by the seeding layer, which knows the answer exactly.
    /// Validated before use (in range, and actually a `.user` message) so a
    /// stale binding degrades to the fallback instead of mis-marking.
    ///
    /// FALLBACK — anchor on the TRAILING SYSTEM RUN, never on
    /// `lastIndex(.system)`. Replayed history carries ARCHIVED system blocks
    /// of its own, positioned after their own user messages. When the turn's
    /// volatile block is not delivered as a system message — it was empty, or
    /// the model has no mid-conversation system support — `lastIndex(.system)`
    /// selects one of those archived blocks, and the cross-turn 1h marker
    /// lands near the START of the conversation, caching almost nothing. That
    /// is a silent, expensive miss, so this reads only a system run that ENDS
    /// the array (the seeded shape) and otherwise answers nil: no cross-turn
    /// marker at all beats one in the wrong place.
    static func currentTurnUserIndex(_ messages: [LLMMessage]) -> Int? {
        if let bound = ConversationPrefixBoundary.currentUserIndex,
           messages.indices.contains(bound),
           messages[bound].role == .user {
            return bound
        }
        guard let last = messages.indices.last, messages[last].role == .system
        else { return nil }
        var runStart = last
        while runStart > 0, messages[runStart - 1].role == .system { runStart -= 1 }
        return messages[..<runStart].lastIndex { $0.role == .user }
    }

    /// Where the CURRENT (5m) boundary marker goes: the newest message that
    /// is NOT a system message. In the seeded shape that is exactly the
    /// current user message (the system message is last); once a within-turn
    /// round has appended past the trailing system it is the newest appended
    /// message, so the next round still reads the whole established prefix.
    static func currentBoundaryIndex(_ messages: [LLMMessage]) -> Int? {
        messages.lastIndex { $0.role != .system }
    }

    /// The v2 PREVIOUS-TURN boundary: the last ASSISTANT message strictly
    /// before the current turn's user message — the end of the transcript
    /// prefix this turn re-sends verbatim, so a marker there is the read the
    /// next turn is built on. Anchored on the current USER message, not on
    /// the system message and not on the current boundary: anchoring on
    /// either would let a within-turn round stamp THIS turn's own assistant
    /// tool_use with the cross-turn 1h TTL. Unlike the v1 `count - 3`
    /// arithmetic it stays correct however many messages the turn appended.
    static func previousTurnBoundaryIndex(_ messages: [LLMMessage]) -> Int? {
        guard let userIndex = currentTurnUserIndex(messages) else { return nil }
        return messages[..<userIndex].lastIndex { $0.role == .assistant }
    }

    /// Completed prior turns visible in this request, counted as assistant
    /// messages — which on v2 includes every assistant message the history
    /// projection REPLAYED, so a resumed session is credited with the turns
    /// it actually carries rather than restarting from zero. Gates the
    /// speculative 1h write: a one-shot (0 or 1 prior turns) would pay the
    /// 2x extended-TTL write premium with no expected reader (1h needs three
    /// reads to break even, against two for 5m).
    static func priorTurnCount(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.role == .assistant ? 1 : 0) }
    }

    /// ONE extended-TTL decision for the WHOLE request.
    ///
    /// ORDERING RULE (Anthropic): entries with the longer TTL must appear
    /// BEFORE shorter ones — a 1h entry may not sit behind a 5m entry in the
    /// tools → system → messages render order. The tools breakpoint is always
    /// FIRST, so it can never be shorter than the system or message markers;
    /// deciding the TTL once, here, and handing the same value to
    /// `makeToolList`, `makeSystemBlocks` and the previous-turn boundary is
    /// what makes that structural instead of a rule three call sites have to
    /// remember. The current-turn boundary is always LAST and always 5m, which
    /// the rule permits.
    ///
    /// Returns nil (plain 5m ephemeral, no `ttl` key on the wire) unless the
    /// request is a v2 prefix turn carrying at least two completed turns.
    static func requestLongTTL(
        usesPrefixShape: Bool,
        messages: [LLMMessage]
    ) -> String? {
        guard usesPrefixShape, priorTurnCount(messages) >= 2 else { return nil }
        return "1h"
    }

    /// Mark the current append-only request boundary and, when a previous
    /// boundary index is supplied, the preceding one. Both indices are
    /// explicit: v1 passes `count - 3` / `count - 1`; v2 passes
    /// `previousTurnBoundaryIndex` / `currentBoundaryIndex`. TTLs are
    /// explicit too — the previous boundary is the CROSS-TURN read (1h), the
    /// current boundary is re-read within this turn's own loop (5m — `nil`,
    /// i.e. no `ttl` key on the wire, byte-identical to the legacy marker).
    ///
    /// INVARIANT, enforced HERE because this is the one place message markers
    /// are written: a `system` message NEVER receives cache_control. The
    /// volatile mid-conversation system message is turn-scoped (it may even
    /// carry `clear_at`), so caching it is meaningless at best and pins
    /// disappearing bytes into the prefix at worst.
    static func addConversationCacheControls(
        _ messages: inout [[String: Any]],
        previousBoundaryIndex: Int?,
        currentBoundaryIndex: Int?,
        previousBoundaryTTL: String? = nil,
        currentBoundaryTTL: String? = nil
    ) {
        func mark(_ index: Int, ttl: String?) {
            guard messages.indices.contains(index),
                  messages[index]["role"] as? String != "system",
                  var content = messages[index]["content"] as? [[String: Any]],
                  var lastBlock = content.last else { return }
            lastBlock["cache_control"] = ephemeralCacheControl(ttl: ttl)
            content[content.count - 1] = lastBlock
            messages[index]["content"] = content
        }
        if let previousBoundaryIndex,
           previousBoundaryIndex != currentBoundaryIndex {
            mark(previousBoundaryIndex, ttl: previousBoundaryTTL)
        }
        if let currentBoundaryIndex {
            mark(currentBoundaryIndex, ttl: currentBoundaryTTL)
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
    ///
    /// V2 PREFIX SHAPE (`ConversationPrefixShape.v2Prefix`, production default,
    /// engaged only when the segments are present and reassemble):
    ///   [identity — NO cache_control] [stable] [stableSuffix?] [dynamic?]
    /// The identity block is a strict PREFIX of the stable mass, so a
    /// breakpoint at the end of the stable mass already caches it; its own
    /// breakpoint bought nothing and spent one of the four slots. The freed
    /// slot funds the previous-turn conversation boundary marker. The LAST
    /// stable block (stableSuffix when present, else stable) carries the
    /// single system breakpoint, at the GA 1h TTL when `longTTL` says so —
    /// see `requestLongTTL`, which also keeps the tools breakpoint at the
    /// same TTL so the render order never puts 5m ahead of 1h. An empty `dynamic`
    /// emits no dynamic block at all.
    /// Byte faithfulness is unchanged: separators ride as SUFFIXES on the
    /// preceding block, so the emitted non-identity block texts concatenate to
    /// `sys` exactly.
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments? = LLMCallContext.systemSegments,
        toolCapable: Bool = false,
        longTTL: String? = nil
    ) -> [[String: Any]] {
        let usesPrefixShape = usesV2PrefixShape(system, segments: segments)
        var blocks: [[String: Any]] = [
            usesPrefixShape
                ? [
                    "type": "text",
                    "text": claudeCodeIdentity,
                ]
                : [
                    "type": "text",
                    "text": claudeCodeIdentity,
                    "cache_control": ephemeralCacheControl,
                ],
        ]
        guard let sys = system, !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return blocks
        }
        if usesPrefixShape, let seg = segments {
            // Separator suffixes: each emitted block carries the "\n\n" that
            // joins it to the NEXT emitted block, so the concatenation of the
            // block texts is `sys` byte-for-byte.
            let hasSuffix = !seg.stableSuffix.isEmpty
            let hasDynamic = !seg.dynamic.isEmpty
            let stableTTL: String? = longTTL
            var stableBlock: [String: Any] = [
                "type": "text",
                "text": seg.stable + ((hasSuffix || hasDynamic) ? "\n\n" : ""),
            ]
            if !hasSuffix {
                stableBlock["cache_control"] = ephemeralCacheControl(ttl: stableTTL)
            }
            blocks.append(stableBlock)
            if hasSuffix {
                blocks.append([
                    "type": "text",
                    "text": seg.stableSuffix + (hasDynamic ? "\n\n" : ""),
                    "cache_control": ephemeralCacheControl(ttl: stableTTL),
                ])
            }
            if hasDynamic {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                ])
            }
            return blocks
        }
        if let seg = segments,
           !seg.stable.isEmpty, !seg.dynamic.isEmpty, seg.stableSuffix.isEmpty,
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

    /// Every `cache_control` marker present on a finished request body, in
    /// Anthropic's render order (tools → system → messages). Derived from the
    /// BODY, not from the placement code, so the telemetry row proves what
    /// actually shipped. Positions and TTLs only — no prompt bytes.
    static func cacheMarkers(in body: [String: Any]) -> [LLMCacheMarker] {
        func ttl(_ container: [String: Any]) -> String? {
            guard let cc = container["cache_control"] as? [String: Any] else { return nil }
            // The 5m default is the ABSENT `ttl` key on the wire.
            return (cc["ttl"] as? String) ?? "5m"
        }
        var out: [LLMCacheMarker] = []
        for (i, tool) in (body["tools"] as? [[String: Any]] ?? []).enumerated() {
            if let t = ttl(tool) { out.append(.init(position: "tools[\(i)]", ttl: t)) }
        }
        for (i, block) in (body["system"] as? [[String: Any]] ?? []).enumerated() {
            if let t = ttl(block) { out.append(.init(position: "system[\(i)]", ttl: t)) }
        }
        for (i, message) in (body["messages"] as? [[String: Any]] ?? []).enumerated() {
            for block in (message["content"] as? [[String: Any]] ?? []) {
                if let t = ttl(block) { out.append(.init(position: "messages[\(i)]", ttl: t)) }
            }
        }
        return out
    }

    /// Three-way wire role. `.system` is the MID-CONVERSATION system message
    /// (Anthropic accepts it inside `messages`); the turn-level system prompt
    /// still travels in the top-level `system` blocks.
    static func wireRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    /// Which prefix shape this REQUEST actually emits.
    ///
    /// READS THE BOUND TASK-LOCAL ONLY — never `ConversationPrefixShape
    /// .effective`. The shape is decided ONCE per turn, at the history
    /// builder's seeding boundary, and bound around the whole call: a turn
    /// that seeded no replayed history seeds the v1 shape and binds
    /// `.v1Legacy`, and the adapter must then emit the v1 bytes exactly.
    /// If the adapter re-derived the shape from `.effective` it would answer
    /// `.v2Prefix` on that turn — dropping the identity breakpoint and adding
    /// a current-message breakpoint to a request the builder shaped as v1.
    /// Unbound (every non-chat caller: dream, REM, executions, tests) →
    /// `.v1Legacy`, i.e. byte-identical to the pre-v2 wire.
    ///
    /// v2 additionally needs the compat lever off AND segments that
    /// make it representable: a non-empty stable segment that reassembles
    /// byte-for-byte into the combined `system` string. Same safety guard as
    /// v1 — a stale or caller-mutated binding falls back to the legacy arm
    /// rather than changing model-visible content — but it tolerates an EMPTY
    /// `dynamic` (the cross-turn shape legitimately has none once history has
    /// moved into the message array).
    static func usesV2PrefixShape(
        _ system: String?,
        segments: SystemPromptSegments?
    ) -> Bool {
        guard ConversationPrefixShape.override == .v2Prefix,
              !GrownPromptCompat.effective,
              let sys = system,
              !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let seg = segments,
              !seg.stable.isEmpty,
              seg.reassembles(into: sys)
        else { return false }
        return true
    }

    /// Anthropic Messages-API tools list with a cache_control breakpoint on
    /// the LAST definition. Returns nil for nil/empty input so the no-tools
    /// request body stays byte-identical to the no-tools overload.
    /// `ttl` MUST match the request's system/message TTL decision — the
    /// tools block renders FIRST, and a 5m entry there would sit ahead of a
    /// 1h entry, which Anthropic rejects as an ordering violation. Defaults
    /// to nil (plain 5m) so every non-v2 caller is byte-identical.
    static func makeToolList(
        _ tools: [LLMToolSchema]?,
        ttl: String? = nil
    ) -> [[String: Any]]? {
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
        toolList[toolList.count - 1]["cache_control"] = ephemeralCacheControl(ttl: ttl)
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
        // V2: EVERY turn is a prefix-reuse turn — the transcript is re-sent
        // as a cached prefix across turns, not only inside one tool loop — so
        // the conversation breakpoints are unconditional (still subject to
        // trailing-eligibility and the compat lever). The v2 system-block
        // shape only engages when the segments actually reassemble; when it
        // does not, the identity block keeps its own breakpoint and there is
        // no free slot, so no previous-turn boundary is marked.
        let usesPrefixShape = Self.usesV2PrefixShape(
            system, segments: LLMCallContext.systemSegments
        )
        // Prove a conversation breakpoint CAN ship before
        // suppressing dynamic-end — an empty messages
        // array (or an empty last content) would otherwise lose BOTH
        // breakpoints silently. Eligibility on the source LLMMessages
        // mirrors the encoder exactly (every content block encodes to
        // one Anthropic block).
        // Eligibility is about the message the CURRENT marker would land on
        // — the newest NON-system message, not `messages.last` (which is the
        // volatile system message in the seeded v2 shape and can never be
        // marked). An empty content array there would silently lose both
        // markers.
        let boundaryIndex = Self.currentBoundaryIndex(messages)
        let trailingEligible = boundaryIndex.map { !messages[$0].content.isEmpty } ?? false
        let useConversationCache =
            (usesPrefixShape || toolCapable || MessagesCacheHint.withinTurnReuse)
            && trailingEligible
            && !Self.GrownPromptCompat.effective
        let longTTL = Self.requestLongTTL(
            usesPrefixShape: usesPrefixShape, messages: messages
        )
        let systemBlocks = Self.makeSystemBlocks(
            system,
            toolCapable: toolCapable && !useConversationCache,
            longTTL: longTTL
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
            var entry: [String: Any] = [
                "role": Self.wireRole(m.role),
                "content": blocks,
            ]
            // Mid-conversation system message the provider drops as soon as
            // the next user message arrives. The `clear_at` key rides on the
            // MESSAGE, and its beta is added per-request in apiHeaders.
            if m.turnScopedClearAtNextUserMessage {
                entry["clear_at"] = "next_user_message"
            }
            anthropicMessages.append(entry)
        }
        if useConversationCache {
            // v2: the previous boundary is the last assistant message before
            // the volatile system message (funded by the identity block's
            // freed slot) and reads at the request's long TTL. v1: the historical
            // `count - 3` arithmetic, plain 5m, byte-identical.
            // The CURRENT marker index is the same rule on both arms: the
            // newest NON-system message. On v1 that is `count - 1` (v1 never
            // carries a mid-conversation system message), so the legacy body
            // stays byte-identical; the rule simply also holds the
            // never-mark-a-system-message invariant if one ever appears.
            let currentIndex = boundaryIndex
            let previousBoundaryIndex: Int?
            let previousBoundaryTTL: String?
            if usesPrefixShape {
                // Indices are computed on the SOURCE messages and applied to
                // `anthropicMessages`: this encoder is 1:1 (every LLMMessage
                // yields exactly one wire entry, empty content included), so
                // the two arrays share indices.
                previousBoundaryIndex = Self.previousTurnBoundaryIndex(messages)
                previousBoundaryTTL = longTTL
                // Budget: stable-end + previous + current + last tool = 4.
                // Nothing else can ship a marker on v2, so this is closed.
            } else {
                // The text lane has one free fourth slot. Structured tools
                // already spend it on the last tool definition.
                let retain = !toolCapable && MessagesCacheHint.withinTurnReuse
                previousBoundaryIndex =
                    (retain && anthropicMessages.count >= 3)
                    ? anthropicMessages.count - 3
                    : nil
                previousBoundaryTTL = nil
            }
            Self.addConversationCacheControls(
                &anthropicMessages,
                previousBoundaryIndex: previousBoundaryIndex,
                currentBoundaryIndex: currentIndex,
                previousBoundaryTTL: previousBoundaryTTL
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
        if let toolList = Self.makeToolList(tools, ttl: longTTL) {
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
        let coercedModel = try Self.coerceToClaudeModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(
                    forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
                lastSentAccessToken = accessToken
            } catch is CancellationError { throw CancellationError() }
            catch let err as LLMError { throw err }
            catch { throw LLMError.notConfigured(provider: "anthropic_oauth_direct") }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(
                accessToken: accessToken, model: coercedModel, messages: messages
            ) {
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
                durationMs: durationMs,
                substitutedFrom: substitutedFrom,
                cacheMarkers: Self.cacheMarkers(in: body)
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
        let coercedModel = try Self.coerceToClaudeModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        // Two-attempt loop mirrors the OpenAI adapter: refresh inline on a
        // 401 once. Avoids the wave-27 double-rotate bug by NOT also
        // refreshing inline on the first 401 — just loops with
        // forceRefresh=true on the second pass.
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(
                    forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
                lastSentAccessToken = accessToken
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
                durationMs: durationMs,
                substitutedFrom: substitutedFrom,
                cacheMarkers: Self.cacheMarkers(in: body)
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Coerce INSIDE the stream task: this is a non-throwing
                    // factory, so an unserviceable model id has to reach the
                    // caller as a thrown continuation finish rather than as a
                    // silently defaulted model (NORTHSTAR clause 2).
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStream(
                        prompt: prompt,
                        system: system,
                        model: coercedModel,
                        substitutedFrom: Self.substitutionTrace(
                            requested: model,
                            coerced: coercedModel
                        ),
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
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
            lastSentAccessToken = accessToken

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
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            if status == 429 {
                // A3.4: honor Retry-After (header available pre-drain).
                throw LLMError.rateLimited(
                    message: "rate limited",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if !(200..<300).contains(status) {
                let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
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
                        durationMs: durationMs,
                        substitutedFrom: substitutedFrom,
                        cacheMarkers: Self.cacheMarkers(in: body)
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Coerce INSIDE the stream task — see stream() above.
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStreamMessages(
                        messages: messages,
                        system: system,
                        model: coercedModel,
                        tools: tools,
                        substitutedFrom: Self.substitutionTrace(
                            requested: model,
                            coerced: coercedModel
                        ),
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
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
            lastSentAccessToken = accessToken

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(
                accessToken: accessToken, model: model, messages: messages
            ) {
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
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            if status == 429 {
                // A3.4: honor Retry-After (header available pre-drain).
                throw LLMError.rateLimited(
                    message: "rate limited",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if !(200..<300).contains(status) {
                let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
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
                            durationMs: durationMs,
                            substitutedFrom: substitutedFrom,
                            cacheMarkers: Self.cacheMarkers(in: body)
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
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil
    ) async throws -> String {
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
            // User, 2026-09-06: the reread was skipped entirely on a forced
            // refresh, so N simultaneous 401s each rotated in turn and every
            // rotation invalidated the single-use refresh_token the next
            // waiter was about to spend — a burst of parallel requests signed
            // the user out. A forced refresh whose on-disk token has already
            // moved past the one the failing request sent takes the new token.
            if forceRefresh, let staleToken, !staleToken.isEmpty,
               let (token, _) = Self.loadAccessTokenAndExpiry(from: path),
               token != staleToken {
                return token
            }
            if !forceRefresh, let (token, exp) = Self.loadAccessTokenAndExpiry(from: path) {
                if let exp = exp, exp.timeIntervalSinceNow > Self.tokenExpiryBufferSec {
                    return token
                }
                if exp == nil { return token }
            }
            return try await self.refreshTokens()
        }
    }

    /// True when a signed-in Anthropic OAuth credential is on disk at this
    /// adapter's own path (User, 2026-09-06 — see `OAuthCredentialPresence`).
    var hasStoredOAuthCredential: Bool {
        Self.loadAccessTokenAndExpiry(from: resolveAuthPath()) != nil
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
        // User, 2026-09-06: the refresh holds the shared serial refresh actor,
        // so it needs a bound of its own rather than the session's chat-sized
        // request timeout — a hung token endpoint otherwise blocks every later
        // turn's token read for minutes.
        req.timeoutInterval = 30
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
            // User, 2026-09-06: a refresh 429 folded into `.transient` threw
            // the provider's own `Retry-After` away, so the reconnect ladder
            // backed off on its own schedule and re-asked into the same limit.
            // The chat call path already carries the header through
            // `.rateLimited`; the refresh does now too.
            if status == 429 {
                throw LLMError.rateLimited(
                    message: "anthropic_oauth_direct refresh HTTP 429 (temporary)",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
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
        let rotatedAccess = (payload["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rotatedRefresh = (payload["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
        let rotatedExpiresAt = f.string(from: exp)

        // User, 2026-09-06: sign-out (which deletes this file) and a fresh
        // sign-in (which replaces it) both land while a refresh is in flight,
        // and neither goes through the adapter's refresh queue. Writing the
        // merged blob unconditionally resurrected a credential the user had
        // just removed, or clobbered a newer one with the older account's
        // tokens. The bytes read before the network call are the generation:
        // if they moved, this refresh is stale and its write is skipped. The
        // access token it minted is still valid, so the in-flight call is
        // served from whatever credential now owns the file.
        // User, 2026-09-06: the comparison and the write it guards now sit in
        // ONE critical section on the credential path's shared lock, which the
        // app's sign-in and sign-out take too — a compare followed by an
        // unguarded write still lost every sign-out that landed between them.
        // User, 2026-09-06: the generation is a digest of the TOKEN keys, not
        // the file's bytes. `configureProvider` writes `default_model` into
        // this same file, so saving provider settings during a refresh moved
        // the bytes and made the refresh discard the token it had just
        // rotated — burning the single-use refresh_token on disk. For the same
        // reason the merge happens against what is on disk NOW, so a
        // concurrent settings save survives the refresh's write.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: data)
        enum RefreshWrite { case wrote, superseded(String), supersededAndGone }
        let outcome: RefreshWrite
        do {
            outcome = try CredentialFileLock.withLock(path) { () -> RefreshWrite in
                guard CredentialFileLock.credentialGeneration(ofFileAt: path) == generation else {
                    guard let (current, _) = Self.loadAccessTokenAndExpiry(from: path) else {
                        return .supersededAndGone
                    }
                    return .superseded(current)
                }
                var blob = (try? Data(contentsOf: path))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    ?? obj
                if let rotatedAccess { blob["access_token"] = rotatedAccess }
                if let rotatedRefresh { blob["refresh_token"] = rotatedRefresh }
                blob["expires_at"] = rotatedExpiresAt
                try saveAuthBlob(blob, to: path)
                return .wrote
            }
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

        switch outcome {
        case .superseded(let current):
            // Another writer owns the file now. Its credential is the live one.
            return current
        case .supersededAndGone:
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        case .wrote:
            break
        }

        guard let newAccess = rotatedAccess ?? (obj["access_token"] as? String),
              !newAccess.isEmpty else {
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

import Foundation
import NativeAgentCore
import PersistenceCore

/// Anthropic Messages API adapter. URLSession is injectable for tests.
public final class AnthropicAdapter: LLMAdapter {
    public let providerId: String
    /// Request timeout for the API-key lane. Same resolved value the OAuth
    /// direct adapters use (240s), so both lanes fail a stalled request the
    /// same way instead of inheriting whatever the injected session carries.
    static let requestTimeoutSeconds: TimeInterval = 240

    // INTERNAL (not private): the native-tools lane lives in
    // LLMClient+AnthropicNativeTools.swift — same module, separate file, so it
    // needs module-internal visibility on the transport seams. Still not
    // public: nothing outside ProviderRouting can reach them.
    let session: URLSession
    let endpoint: URL
    private let apiKeyOverride: String?
    /// Credential discovery seam. The Anthropic Messages wire protocol is
    /// shared verbatim by first-party subscription providers that speak it at
    /// a different endpoint (e.g. Kimi Code at api.kimi.com/coding) — those
    /// providers reuse this adapter with a distinct providerId + credential
    /// env var / config file rather than forking the wire code
    /// (shared-primitives rule). Defaults preserve the Anthropic api-key path.
    private let credentialEnvVar: String
    private let credentialConfigFile: String
    /// When non-nil, credential discovery is confined to this data root.
    /// Production callers may leave it nil to preserve dynamic default-root
    /// resolution; tests and secondary runtimes must inject their own root.
    private let dataRootOverride: URL?
    let maxTokensOverride: Int?
    /// F1-H1: cadence of the native-tools `streamMessages` keepalive heartbeat
    /// (seconds). The override is a single blocking call that yields nothing
    /// until it returns, so a `.keepAlive` is emitted this often to keep
    /// ProviderStreamGuard's idle clock alive during long silent thinking.
    /// 30s in production (well under the 90s idle default); injectable so tests
    /// can drive it under a short idle window without waiting 30 wall seconds.
    let nativeToolKeepAliveInterval: TimeInterval
    /// Does THIS instance talk to Anthropic's own first-party Messages API
    /// (api.anthropic.com, `x-api-key`)? True for the default init, false for
    /// `kimiCode()`.
    ///
    /// It gates the two native-tool behaviors that are documented by Anthropic
    /// but were never wire-probed against Kimi's coding endpoint:
    ///   1. REAL SSE tool streaming (content_block_start → input_json_delta →
    ///      content_block_stop). kimi-code deliberately rides the blocking
    ///      call + keepalive shape it launched on (see streamMessages).
    ///   2. `strict: true` on closed tool schemas, so the PROVIDER validates
    ///      structured arguments instead of the repair machinery downstream.
    /// Set at construction — never re-derived from `providerId` at a call
    /// site, so there is exactly one place to audit.
    let firstPartyAnthropicToolContract: Bool
    /// U1 step 1 — per-call llm.call telemetry writer (override is test-only).
    let telemetry: LLMCallTraceRecorder
    /// Native-tools lane only: the thinking blocks that came back with each
    /// tool-calling response, keyed by that response's tool_use ids, so the
    /// next round can replay them (claude-fable-5-1 has thinking always on and
    /// 400s on a tool_result round whose assistant turn dropped them). In
    /// memory, bounded, never persisted — see AnthropicThinkingLedger.
    let thinkingLedger = AnthropicThinkingLedger()

    private var credentialRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    private var includesProcessEnvironmentCredentials: Bool {
        dataRootOverride == nil
            || credentialRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    /// The exact credential-discovery ladder every request path in this
    /// adapter uses, in one place so the native-tools lane cannot drift from
    /// it (override → env var → provider config file, all confined to the
    /// injected data root).
    func resolvedCredentialKey() throws -> String {
        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: credentialEnvVar,
                    providerConfigFile: credentialConfigFile,
                    dataRoot: credentialRoot,
                    includeEnvironment: includesProcessEnvironmentCredentials),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: providerId)
        }
        return key
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        apiKeyOverride: String? = nil,
        maxTokens: Int? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil,
        providerId: String = "anthropic",
        credentialEnvVar: String = "ANTHROPIC_API_KEY",
        credentialConfigFile: String = "anthropic.json",
        nativeToolKeepAliveInterval: TimeInterval = 30,
        firstPartyAnthropicToolContract: Bool = true
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.maxTokensOverride = maxTokens
        self.dataRootOverride = dataRootOverride
        self.providerId = providerId
        self.credentialEnvVar = credentialEnvVar
        self.credentialConfigFile = credentialConfigFile
        self.nativeToolKeepAliveInterval = max(0.001, nativeToolKeepAliveInterval)
        self.firstPartyAnthropicToolContract = firstPartyAnthropicToolContract
        // Keep credential discovery and telemetry inside the same injected
        // body by default. A caller may still override telemetry explicitly,
        // but a secondary/test provider root must never leak traces into the
        // live personal root merely because it omitted a second argument.
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    func requestMaxTokens(model: String) -> Int {
        if let limit = LLMCallContext.botOutputTokenLimit { return limit }
        return FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: LLMCallContext.reasoningEffort,
            explicitOverride: maxTokensOverride
        )
    }

    /// Kimi Code SUBSCRIPTION adapter: the hardened Anthropic Messages wire
    /// path pointed at the subscription endpoint (api.kimi.com/coding, Claude
    /// Code appends v1/messages) with the kimi-code credential seam. Single
    /// source of the endpoint literal so the wire code stays one copy
    /// (shared-primitives rule). providerId "kimi-code" flows into telemetry
    /// and every notConfigured surface.
    public static func kimiCode(
        session: URLSession = .shared,
        apiKeyOverride: String? = nil,
        // Keep Kimi's explicit 32768 override independent of Claude's
        // model/effort-aware default: K3-class thinking is always
        // on and counts against max_tokens — live-probed 2026-07-19: a
        // substantive task at max effort consumed 8192 entirely in thinking
        // (stop_reason=max_tokens, zero text blocks). max_tokens is a cap,
        // not a spend; the headroom is free until used.
        maxTokens: Int = 32_768,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil,
        nativeToolKeepAliveInterval: TimeInterval = 30
    ) -> AnthropicAdapter {
        AnthropicAdapter(
            session: session,
            endpoint: URL(string: "https://api.kimi.com/coding/v1/messages")!,
            apiKeyOverride: apiKeyOverride,
            maxTokens: maxTokens,
            dataRootOverride: dataRootOverride,
            telemetryDataRootOverride: telemetryDataRootOverride,
            providerId: "kimi-code",
            credentialEnvVar: "KIMI_CODE_API_KEY",
            credentialConfigFile: "kimi-code.json",
            nativeToolKeepAliveInterval: nativeToolKeepAliveInterval,
            // Kimi's coding endpoint was probed for shapes A/B/C only (request
            // tools[], tool_use response, tool_result replay, parallel calls).
            // Its SSE tool framing and its handling of `strict` are unprobed,
            // so this lane keeps the exact wire it launched on.
            firstPartyAnthropicToolContract: false
        )
    }

    /// U1 step 3 + 2b/3b — system as a BLOCK ARRAY with an ephemeral
    /// cache_control breakpoint. The Messages API accepts `system` as a
    /// plain string OR an array of text blocks; only the block-array form
    /// can carry cache_control. This adapter has no claudeCodeIdentity block
    /// (that's OAuth-mode-only) and never ships tools (the LLMAdapter
    /// default forwards drop them).
    ///
    /// With a stable/dynamic split bound via LLMCallContext.systemSegments
    /// (U1 2b/3b) that reassembles byte-for-byte into `system`
    /// (INVARIANT: system == stable + "\n\n" + dynamic), the breakpoint
    /// moves to the END of the stable block (persona+pins) and the dynamic
    /// block (recall+history) follows uncached — the per-turn churn stops
    /// invalidating the stable prefix. Without segments (or on any
    /// mismatch), the single combined sys-block breakpoint is byte-identical
    /// to the pre-2b/3b request shape.
    ///
    /// BYTE FAITHFULNESS (gpt-5.5 review blocker, 2026-06-10): the API does
    /// not guarantee any particular join between adjacent text blocks, so
    /// the emitted block texts must concatenate byte-for-byte to `system`.
    /// The "\n\n" separator rides as a SUFFIX on the stable block's text
    /// (cache-safe: the suffix is exactly as stable as the block itself).
    ///
    /// `cacheEligible` (2026-07-21 audit; mirrors the OAuth adapter's
    /// toolCapable gate): the COMBINED-block fallback carries an ephemeral
    /// breakpoint ONLY for cache-eligible callers — a chat turn, which binds
    /// `LLMCallContext.sessionId` around every adapter call and re-sends the
    /// same persona mass turn after turn. One-shot callers (background loops,
    /// dream/REM) bind no session context; stamping the breakpoint there pays
    /// Anthropic's 1.25x cache-WRITE premium with ~zero read probability, so
    /// they emit the plain block. The segmented split is unaffected (segments
    /// are only ever bound on chat turns, alongside sessionId).
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments? = LLMCallContext.systemSegments,
        cacheEligible: Bool = LLMCallContext.sessionId != nil
    ) -> [[String: Any]]? {
        guard let sys = system, !sys.isEmpty else { return nil }
        if let seg = segments,
           !seg.stable.isEmpty, !seg.dynamic.isEmpty,
           seg.reassembles(into: sys)
        {
            // `stableSuffix` is session-stable text assembled AFTER `stable`
            // (e.g. the "Also loaded this session" tool catalog). It rides
            // INSIDE the cached prefix as its own block, and the breakpoint
            // moves to the LAST stable block so `stable` stays a strict
            // prefix of the cached mass. Emitting only [stable][dynamic]
            // here would silently DROP it from the model's view — the
            // reassembles() guard passes either way, because it checks the
            // SEGMENTS against `sys`, not the blocks this branch emits.
            // Separators ride as suffixes, so the block texts still
            // concatenate to `sys` byte-for-byte; with an empty suffix the
            // emitted blocks are byte-identical to the old two-block shape.
            let hasSuffix = !seg.stableSuffix.isEmpty
            var blocks: [[String: Any]] = [[
                "type": "text",
                "text": seg.stable + "\n\n",
            ]]
            if hasSuffix {
                blocks.append([
                    "type": "text",
                    "text": seg.stableSuffix + "\n\n",
                    "cache_control": ["type": "ephemeral"],
                ])
            } else {
                blocks[0]["cache_control"] = ["type": "ephemeral"]
            }
            // Dynamic tail: NO cache_control — churns per turn.
            blocks.append([
                "type": "text",
                "text": seg.dynamic,
            ])
            return blocks
        }
        if cacheEligible {
            return [[
                "type": "text",
                "text": sys,
                "cache_control": ["type": "ephemeral"],
            ]]
        }
        // One-shot caller (no chat-turn session bound): skip the breakpoint —
        // the write premium would never be earned back by a read.
        return [[
            "type": "text",
            "text": sys,
        ]]
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: credentialEnvVar,
                    providerConfigFile: credentialConfigFile,
                    dataRoot: credentialRoot,
                    includeEnvironment: includesProcessEnvironmentCredentials),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: providerId)
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // An injected session may carry URLSession's 60s default (or none at
        // all); match the OAuth lanes' resolved 240s so a stalled completion
        // fails instead of hanging the turn.
        req.timeoutInterval = Self.requestTimeoutSeconds

        var body: [String: Any] = [
            "model": model,
            "max_tokens": requestMaxTokens(model: model),
            "messages": [["role": "user", "content": prompt]],
        ]
        if let systemBlocks = Self.makeSystemBlocks(system) {
            body["system"] = systemBlocks
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
        applyThinkingControls(to: &body)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performCompletion(request: req, model: model)
    }

    /// Shared HTTP validation, text-block parsing and usage for both request shapes.
    private func performCompletion(request req: URLRequest, model: String) async throws -> String {
        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Cancellation MUST propagate as CancellationError so structured-
            // concurrency callers can distinguish cancel from a real network
            // failure. URLSession surfaces cancel as NSURLErrorDomain + NSURLErrorCancelled (R-M2).
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "anthropic")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A3.1: a key IS present here (missing-key guards threw .notConfigured
        // above), so a 401 is a positive credential rejection. Carry the
        // provider's own message (kimi-code / Anthropic error body).
        if status == 401 {
            throw LLMError.authRejected(provider: providerId, detail: providerErrorDetail(data))
        }
        if status == 429 {
            let msg = String(data: data, encoding: .utf8) ?? "rate limited"
            throw LLMError.rateLimited(message: msg, retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if (500..<600).contains(status) {
            let body = String(data: data, encoding: .utf8) ?? "5xx"
            // User, 2026-09-06: the raw body alone discarded the status, and
            // ProviderRecoveryPolicy classifies `.underlying` by reading a code
            // out of the message — so a 5xx here rode the phrase ladder or
            // nothing at all. Name the status the way the policy parses it.
            throw LLMError.underlying(message: "\(providerId) HTTP \(status): \(body)")
        }
        guard (200..<300).contains(status) else {
            // Preserve the provider's own explanation (2026-07-19: a Kimi 403
            // carried "usage limit for this billing cycle…" and we threw it
            // away, surfacing "(internal error)" to User's Telegram). Anthropic
            // error shape: {"error":{"type":…,"message":…}}.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String, !message.isEmpty {
                throw LLMError.providerError(
                    message: "\(providerId): \(String(message.prefix(300))) (HTTP \(status))")
            }
            throw LLMError.invalidResponse(status: status)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw malformedSuccessBodyError(data)
        }
        // Thinking models (K3, Claude extended thinking) lead with a thinking
        // block — join all text blocks instead of requiring content[0].text.
        let text = Self.joinedTextBlocks(content)
        guard !text.isEmpty else {
            throw emptyTextResponseError(obj, content: content)
        }
        // U1 step 1: token/cache usage telemetry (non-fatal, numbers only).
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return text
    }

    // MARK: - Structured messages (native vision)

    /// Native-vision `completeMessages` override. The api-key Anthropic path is
    /// a fallthrough in the user's OAuth setup, but we wire real vision here too so
    /// no provider/credential combo silently loses images.
    ///
    /// BYTE-IDENTITY: when the conversation carries NO image block, we DELEGATE
    /// to `complete(prompt:)` via the inherited default flatten — that keeps the
    /// text-only request body byte-identical to the pre-vision path. We only
    /// build a structured Messages-API body when an `.image` block is present.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // NATIVE TOOL LANE (kimi-code only — see NativeToolCapability). The
        // String return can't carry tool calls, so a native call that produced
        // them renders each as the exact id-bearing marker ToolCallParser
        // already understands. That keeps this path honest for String callers
        // instead of silently dropping the model's chosen action; callers that
        // can ACT on tool calls use completeMessagesWithTools directly, which
        // is what the chat loop does via streamMessages.
        if usesNativeToolLane(tools), let tools {
            let result = try await completeMessagesWithTools(
                messages: messages, system: system, model: model, tools: tools
            )
            guard !result.toolCalls.isEmpty else { return result.text }
            let markers = result.toolCalls.map { call -> String in
                let args = String(data: call.inputJSON, encoding: .utf8) ?? "{}"
                return "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
            }.joined()
            return result.text + markers
        }
        let hasImage = messages.contains { m in
            m.content.contains { if case .image = $0 { return true }; return false }
        }
        guard hasImage else {
            // Preserve this adapter's SYSTEM prefix. No images → no tripwire note.
            let flattened = llmCompatibilityPrompt(messages: messages) { role in
                switch role {
                case .user: "USER:"
                case .assistant: "ASSISTANT:"
                case .system: "SYSTEM:"
                }
            }
            let combined = flattened.text
            return try await complete(prompt: combined, system: system, model: model)
        }

        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: credentialEnvVar,
                    providerConfigFile: credentialConfigFile,
                    dataRoot: credentialRoot,
                    includeEnvironment: includesProcessEnvironmentCredentials),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: providerId)
        }

        // Encode each message as an Anthropic message with a content-block
        // array. Image → base64 image block; text → text block; tool blocks
        // flattened to text (the api-key path never ships native tools).
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text(let t):
                    blocks.append(["type": "text", "text": t])
                case .image(let mediaType, let base64, _, _):
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64,
                        ],
                    ])
                case .toolUse(_, let name, let inputJSON):
                    let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                    blocks.append(["type": "text", "text": "[tool_use \(name) \(argsStr)]"])
                case .toolResult(_, let content, _):
                    blocks.append(["type": "text", "text": "[tool_result] \(content)"])
                }
            }
            // Mid-conversation tool changes never ride THIS lane (it ships no
            // `tools` array, so there is nothing a `tool_reference` could name
            // and any block here would be a 400). Drop a message that carries
            // nothing else rather than emitting an empty `content` array,
            // which the Messages API rejects. Unreachable in production — the
            // structured native lane is the only producer — and byte-identical
            // for every message that has content.
            guard !blocks.isEmpty else { continue }
            // Three-way role: a `.system` message is emitted as a
            // MID-CONVERSATION system message here too, so the api-key lane
            // never silently relabels it as assistant text. `clear_at` rides
            // with it; the api-key transport sends no beta header, so a model
            // that cannot honour it will reject the request loudly rather
            // than silently dropping the turn-scoped semantics.
            var entry: [String: Any] = [
                "role": AnthropicOAuthDirectAdapter.wireRole(m.role),
                "content": blocks,
            ]
            if m.turnScopedClearAtNextUserMessage {
                entry["clear_at"] = "next_user_message"
            }
            anthropicMessages.append(entry)
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // An injected session may carry URLSession's 60s default (or none at
        // all); match the OAuth lanes' resolved 240s so a stalled completion
        // fails instead of hanging the turn.
        req.timeoutInterval = Self.requestTimeoutSeconds
        // clear_at in the body REQUIRES its beta header. Same rule as the
        // OAuth lane: present iff a message carries the flag, absent
        // otherwise, so every pre-existing request stays byte-identical.
        if let beta = AnthropicOAuthDirectAdapter.midConversationBetas(for: messages) {
            req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": requestMaxTokens(model: model),
            "messages": anthropicMessages,
        ]
        if let systemBlocks = Self.makeSystemBlocks(system) {
            body["system"] = systemBlocks
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
        applyThinkingControls(to: &body)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // User, 2026-09-06: carry the status — see the sibling above.
        return try await performCompletion(request: req, model: model)
    }

    // MARK: - Streaming (SSE)

    /// Anthropic Messages API in streaming mode. Parses SSE frames of shape:
    ///   event: content_block_delta
    ///   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
    /// Yields the inner `delta.text` only — ignores message_start/stop, ping,
    /// thinking deltas, and tool_use chunks (those route through ToolLoop).
    /// Kimi Code reasoning control on the Anthropic wire: Kimi's canonical
    /// knob is a TOP-LEVEL `reasoning_effort` ("low"/"high"/"max"), NOT the
    /// Anthropic `thinking` budget (their docs: "Do not use the K2.x thinking
    /// parameter"; K3 thinking is ALWAYS on and cannot be disabled).
    /// Live-probed 2026-07-19 against api.kimi.com/coding with a real key:
    /// all three levels 200 on k3 AND kimi-for-coding; unknown values are
    /// tolerated (no 400). Scoped to kimi-code — Claude api-key behavior is
    /// unchanged. "none"/unset omits the field → provider default (max per
    /// their docs). Legacy "medium" picks map to "high".
    func applyThinkingControls(to body: inout [String: Any]) {
        guard providerId == "kimi-code" else { return }
        let effort = (LLMCallContext.reasoningEffort ?? "none")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch effort {
        case "low": body["reasoning_effort"] = "low"
        case "medium", "high": body["reasoning_effort"] = "high"
        case "max": body["reasoning_effort"] = "max"
        case "none", "":
            // Intentional: omit the key → provider default (max per Kimi docs).
            // "none"/unset is a deliberate "no pin", NOT a misconfiguration.
            break
        default:
            // F1-L1: an UNRECOGNIZED reasoning_effort string is a misconfigured
            // surface pin. Omitting the key would silently fall to the provider
            // default ("max" — the 32k-thinking, most-expensive setting), hiding
            // the bad config behind the priciest behavior. Clamp to "high": a
            // catalog-supported value (low/high/max all live-probed 200 on
            // 2026-07-19), the safe middle — real reasoning without the runaway
            // max budget — and NOT the silent default. Log one diagnostic line
            // so the misconfigured surface is discoverable.
            FileHandle.standardError.write(Data((
                "[applyThinkingControls] kimi-code: unrecognized reasoning_effort "
                + "'\(effort)' — clamping to 'high'\n").utf8))
            body["reasoning_effort"] = "high"
        }
    }

    /// Anthropic-shape content extraction tolerant of thinking models: K3 (and
    /// Claude with extended thinking) leads the content array with a
    /// `thinking` block, so demanding `content[0]` be text throws
    /// invalidResponse on a perfectly good 200 (the kimi-code launch bug).
    /// Joins every text block instead.
    static func joinedTextBlocks(_ content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            let type = block["type"] as? String ?? "text"
            guard type == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    /// Names an HTTP-200 response that carried zero answer text — the error a
    /// caller sees must say WHAT came back, not "invalid response status 200"
    /// (that anonymous form sent the K3 debugging in the wrong direction three
    /// times, 2026-07-19/20). max_tokens truncation stays a providerError (a
    /// retry of the same request truncates again); every other textless 200 is
    /// a transient provider glitch — `llm: transient` is what the surface retry
    /// ladders match on, and ProviderErrorAfterToolEffects still vetoes
    /// whole-turn replays once tool effects exist.
    func emptyTextResponseError(_ obj: [String: Any], content: [[String: Any]]) -> LLMError {
        let stopReason = (obj["stop_reason"] as? String) ?? "absent"
        if stopReason == "max_tokens" {
            return LLMError.providerError(message:
                "\(providerId): thinking consumed the entire max_tokens budget "
                + "before any answer text (stop_reason=max_tokens); raise "
                + "max_tokens or lower the reasoning effort")
        }
        // Anthropic documents stop_reason=refusal as a NORMAL empty-content
        // 200 (model declined). Deterministic — replaying the same request
        // refuses again, so never classify it transient (gpt-5.5, 2026-07-20).
        if stopReason == "refusal" {
            return LLMError.providerError(message:
                "\(providerId): model declined to answer (stop_reason=refusal)")
        }
        var kindCounts: [String: Int] = [:]
        for block in content {
            kindCounts[(block["type"] as? String) ?? "untyped", default: 0] += 1
        }
        let blockSummary = kindCounts.isEmpty
            ? "empty content array"
            : kindCounts.sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        return LLMError.transient(message:
            "\(providerId): HTTP 200 with no answer text "
            + "(stop_reason=\(stopReason); content: \(blockSummary))")
    }

    /// A 200 whose body has no `content` array is either a provider error
    /// envelope smuggled under a success status, or a shape we don't know.
    /// Surface the provider's own message when present; otherwise include a
    /// bounded body prefix so the next occurrence is diagnosable from the log
    /// line alone.
    func malformedSuccessBodyError(_ data: Data) -> LLMError {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String, !message.isEmpty {
            return LLMError.providerError(
                message: "\(providerId): \(String(message.prefix(300))) (HTTP 200 error envelope)")
        }
        let prefix = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        return LLMError.providerError(
            message: "\(providerId): HTTP 200 with unrecognized body shape: \(prefix)")
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let apiKeyOverride = self.apiKeyOverride
        let maxTokens = requestMaxTokens(model: model)
        let credentialRoot = self.credentialRoot
        let includesProcessEnvironmentCredentials = self.includesProcessEnvironmentCredentials
        let telemetry = self.telemetry
        let providerId = self.providerId
        let credentialEnvVar = self.credentialEnvVar
        let credentialConfigFile = self.credentialConfigFile
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let key = apiKeyOverride
                        ?? LLMCredentialResolver.resolveAPIKey(
                            envVar: credentialEnvVar,
                            providerConfigFile: credentialConfigFile,
                            dataRoot: credentialRoot,
                            includeEnvironment: includesProcessEnvironmentCredentials),
                      !key.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured(provider: providerId))
                    return
                }

                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.setValue("text/event-stream", forHTTPHeaderField: "accept")

                var body: [String: Any] = [
                    "model": model,
                    "max_tokens": maxTokens,
                    "stream": true,
                    "messages": [["role": "user", "content": prompt]],
                ]
                if let systemBlocks = Self.makeSystemBlocks(system) {
                    body["system"] = systemBlocks
                }
                FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
                applyThinkingControls(to: &body)
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: LLMError.underlying(message: "encode: \(error)"))
                    return
                }

                let requestStartNs = DispatchTime.now().uptimeNanoseconds
                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: req)
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "anthropic")")))
                    return
                }
                defer { bytes.task.cancel() }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 {
                    // A3.4: honor Retry-After (header is available pre-drain).
                    continuation.finish(throwing: LLMError.rateLimited(
                        message: "rate limited",
                        retryAfterSeconds: parseRetryAfterSeconds(from: response)))
                    return
                }
                if !(200..<300).contains(status) {
                    // Same body preservation as the non-streaming paths: drain
                    // a bounded chunk so a 403 quota / auth message reaches the user.
                    let errData: Data
                    do {
                        errData = try await ProviderErrorBodyDrain.read(
                            bytes, maxBytes: 4096, timeout: 2.0
                        )
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    // A3.1: a key IS present (missing-key guards fired earlier),
                    // so a 401 is a positive credential rejection — carry detail.
                    if status == 401 {
                        continuation.finish(throwing: LLMError.authRejected(
                            provider: providerId, detail: providerErrorDetail(errData)))
                        return
                    }
                    if let obj = try? JSONSerialization.jsonObject(with: errData) as? [String: Any],
                       let err = obj["error"] as? [String: Any],
                       let message = err["message"] as? String, !message.isEmpty {
                        continuation.finish(throwing: LLMError.providerError(
                            message: "\(providerId): \(String(message.prefix(300))) (HTTP \(status))"))
                        return
                    }
                    continuation.finish(throwing: LLMError.invalidResponse(status: status))
                    return
                }

                do {
                    // R15: SSEEventStream owns framing (event:/data: association,
                    // CRLF, multi-line data, EOF flush); this loop owns Anthropic
                    // protocol semantics. `event: error` mid-stream (overloaded /
                    // rate-limit / server hiccup) throws; EOF without
                    // `message_stop` is a truncation.
                    // U1 step 1 — streaming telemetry: usage from
                    // message_start + message_delta, TTFT at first yielded
                    // text delta, llm.call row recorded on message_stop.
                    var usage = LLMUsage()
                    var ttftMs: Int?
                    var yieldedAnyText = false
                    var lastStopReason: String?
                    for try await sse in SSEEventStream(bytes) {
                        try Task.checkCancellation()
                        let payload = sse.data
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Dispatch by event type. Anthropic SSE always pairs event:
                        // with data:, so the event name is authoritative; the payload's
                        // own `type` field is a useful fallback for resilience.
                        let payloadType = obj["type"] as? String ?? ""
                        let eventName = sse.event ?? ""
                        let effectiveEvent = eventName.isEmpty ? payloadType : eventName

                        switch effectiveEvent {
                        case "error":
                            // {"type":"error","error":{"type":"overloaded_error","message":"..."}}
                            let errObj = obj["error"] as? [String: Any]
                            let message = (errObj?["message"] as? String)
                                ?? (errObj?["type"] as? String)
                                ?? "unknown error"
                            throw LLMError.providerError(message: "Anthropic: \(message)")
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
                            // Documented terminal event. Finish clean and return —
                            // don't trust any bytes after this.
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
                            guard let delta = obj["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                guard let text = delta["text"] as? String, !text.isEmpty
                                else { continue }
                                if ttftMs == nil {
                                    ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                                }
                                yieldedAnyText = true
                                continuation.yield(text)
                            case "thinking_delta", "input_json_delta":
                                // Liveness (2026-07-21 audit; port of the OAuth
                                // adapter's .keepAlive fix to this legacy String
                                // stream): thinking/tool-arg deltas are real model
                                // output but carry no user-visible reply text.
                                // ProviderStreamGuard's idle clock only advances on
                                // a yield, so without a signal here a healthy
                                // long-thinking kimi-code turn gets KILLED at the
                                // 90s idle default. A String stream has no
                                // .keepAlive event, so yield an EMPTY string —
                                // content-invisible (`accumulated += ""` is a
                                // no-op and consumers' `!delta.isEmpty` guards skip
                                // it) but it resets the guard's activity clock.
                                continuation.yield("")
                            default:
                                continue
                            }
                        default:
                            // ping, content_block_start/stop — safe to ignore.
                            continue
                        }
                    }
                    // Loop exited via EOF without hitting `case "message_stop"`.
                    // That's a truncated stream — surface it so partial replies
                    // don't look like clean ends.
                    throw LLMError.streamTruncated(
                        message: "Anthropic stream ended without message_stop"
                    )
                } catch let err as LLMError {
                    // Preserve typed errors so callers can pattern-match (providerError
                    // / streamTruncated / notConfigured all need to survive intact).
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
}

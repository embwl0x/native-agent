import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared buffered Messages response operation, credential discovery, prompt blocks and thinking/tool wire controls |

/// Anthropic Messages API adapter. URLSession is injectable for tests.
public final class AnthropicTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String
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
    private let credentialConfigFile: String
    /// When non-nil, credential discovery is confined to this data root.
    /// Production callers may leave it nil to preserve dynamic default-root
    /// resolution; tests and secondary runtimes must inject their own root.
    private let dataRootOverride: URL?
    let maxTokensOverride: Int?
    /// Does THIS instance talk to Anthropic's own first-party Messages API
    /// (api.anthropic.com, `x-api-key`)? True for the default init, false for
    /// `kimiCode()`.
    ///
    /// It gates first-party strict tool schemas, signed thinking replay and
    /// Anthropic conversation cache markers. All message stream routes use real SSE.
    /// Set at construction — never re-derived from `providerId` at a call
    /// site, so there is exactly one place to audit.
    let firstPartyAnthropicToolContract: Bool
    /// Per-call llm.call telemetry writer (override is test-only).
    let telemetry: LLMCallTraceRecorder
    /// Bounded in-memory thinking replay, keyed by the response's tool-use IDs.
    let thinkingLedger = ToolCallReplayLedger<[AnthropicThinkingBlock]>()

    private var credentialRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    /// Every Messages path uses the same credential, headers and sorted body encoding.
    func request(body: [String: Any]) throws -> URLRequest {
        guard let key = try apiKeyOverride
                ?? LLMCredentialResolver.checkedAPIKey(
                    providerConfigFile: credentialConfigFile,
                    dataRoot: credentialRoot),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: providerId)
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        apiKeyOverride: String? = nil,
        maxTokens: Int? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil,
        providerId: String = "anthropic",
        credentialConfigFile: String = "anthropic.json",
        firstPartyAnthropicToolContract: Bool = true
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.maxTokensOverride = maxTokens
        self.dataRootOverride = dataRootOverride
        self.providerId = providerId
        self.credentialConfigFile = credentialConfigFile
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
        if let limit = LLMCallContext.turnTokenBudget?.available { return limit }
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
        // Kimi's separate token cap includes its always-on thinking.
        maxTokens: Int = 32_768,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) -> AnthropicTransport {
        AnthropicTransport(
            session: session,
            endpoint: URL(string: "https://api.kimi.com/coding/v1/messages")!,
            apiKeyOverride: apiKeyOverride,
            maxTokens: maxTokens,
            dataRootOverride: dataRootOverride,
            telemetryDataRootOverride: telemetryDataRootOverride,
            providerId: "kimi-code",
            credentialConfigFile: "kimi-code.json",
            // Kimi shares SSE framing, without first-party strict schemas,
            // signed thinking replay or Anthropic cache markers.
            firstPartyAnthropicToolContract: false
        )
    }

    /// System block texts concatenate byte-for-byte to `system`, with separators on preceding blocks.
    /// Valid segments put the cache breakpoint at the stable end; otherwise the system stays combined.
    /// Combined blocks carry a cache breakpoint only for callers with a session context.
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
            let layout = seg.textBlockLayout
            return layout.texts.enumerated().map { index, text in
                var block: [String: Any] = ["type": "text", "text": text]
                if index == layout.lastStableIndex { block["cache_control"] = ["type": "ephemeral"] }
                return block
            }
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

    /// The prompt lane sends no native tools; those ride the messages lane.
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?) async throws -> String {
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
        return try await performCompletion(request: request(body: body), model: model).text
    }

    /// Buffered Messages validation and receipts; only native-tool requests interpret tool/thinking blocks.
    func performCompletion(
        request req: URLRequest, model: String, nativeTools: Bool = false
    ) async throws -> AnthropicNativeToolResult {
        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            let (bytes, head) = try await ProviderWire.open(session, req)
            defer { bytes.task.cancel() }
            response = head
            data = try await bytes.reduce(into: Data()) { $0.append($1) }
        } catch {
            // URLSession cancellation propagates as CancellationError, distinct from network failure.
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "anthropic")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Preserve the HTTP status even with an empty body.
        try throwIfChatCompletionsError(status: status, data: data, response: response)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw malformedSuccessBodyError(data)
        }
        // Thinking models (K3, Claude extended thinking) lead with a thinking
        // block — join all text blocks instead of requiring content[0].text.
        let text = Self.joinedTextBlocks(content)
        if obj["stop_reason"] as? String == "max_tokens" {
            await telemetry.record(
                requestBody: req.httpBody,
                provider: providerId,
                model: model,
                streaming: false,
                usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
                status: "incomplete",
                stopReason: "max_tokens"
            )
            throw LLMError.outputLengthLimit(partial: text)
        }
        let toolCalls = try (nativeTools ? Self.nativeToolCalls(content) : [])
        if nativeTools {
            let thinking = Self.nativeThinkingBlocks(content)
            if !toolCalls.isEmpty, !thinking.isEmpty {
                await thinkingLedger.record(thinking, callIDs: toolCalls.map(\.id))
            }
        }
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw emptyTextResponseError(obj, content: content)
        }
        // Token/cache usage telemetry is non-fatal and contains numbers only.
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            requestBody: req.httpBody,
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return AnthropicNativeToolResult(
            text: text, toolCalls: toolCalls, stopReason: obj["stop_reason"] as? String
        )
    }

    // MARK: - Structured messages (native vision)

    /// The `anthropic` and `kimi-code` routes select this Messages transport directly.
    /// Non-nil tools retain native blocks; with nil tools, text-only calls keep
    /// role-prefixed compatibility flattening and image calls use content blocks.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // NATIVE TOOL LANE (this adapter's declared `toolWire`). The
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
            let flattened = try llmCompatibilityPrompt(messages: messages) { role in
                switch role {
                case .user: "USER:"
                case .assistant: "ASSISTANT:"
                case .system: "SYSTEM:"
                }
            }
            let combined = flattened.text
            return try await complete(prompt: combined, system: system, model: model, tools: tools)
        }

        // Encode each message as an Anthropic message with a content-block
        // array. Image → base64 image block; text → text block; tool blocks
        // flattened to text (the api-key path never ships native tools).
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text, .image:
                    blocks.append(Self.anthropicBlock(block))
                case .toolUse(_, let name, let inputJSON):
                    let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                    blocks.append(["type": "text", "text": "[tool_use \(name) \(argsStr)]"])
                case .toolResult(_, let content, _):
                    blocks.append(["type": "text", "text": "[tool_result] \(content)"])
                }
            }
            // The Messages API rejects an empty content array.
            guard !blocks.isEmpty else { continue }
            // Three-way role: a `.system` message is emitted as a
            // MID-CONVERSATION system message here too, so the api-key lane
            // never silently relabels it as assistant text. A model
            // that cannot honour it will reject the request loudly rather
            // than silently changing its role.
            let entry: [String: Any] = [
                "role": AnthropicOAuthTransport.wireRole(m.role),
                "content": blocks,
            ]
            anthropicMessages.append(entry)
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
        return try await performCompletion(request: request(body: body), model: model).text
    }

    // MARK: - Thinking controls

    /// Kimi uses top-level `reasoning_effort`; its thinking is always on.
    /// Unset/none omits the field, medium maps to high, and low/high/max pass through.
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
            // Unknown effort uses "high" with a diagnostic instead of the provider's "max" default.
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

    /// Empty HTTP-200 replies name the stop reason to distinguish limits, refusals and missing text.
    func emptyTextResponseError(_ obj: [String: Any], content: [[String: Any]]) -> LLMError {
        let stopReason = (obj["stop_reason"] as? String) ?? "absent"
        if stopReason == "max_tokens" {
            return LLMError.providerError(message:
                "\(providerId): thinking consumed the entire max_tokens budget "
                + "before any answer text (stop_reason=max_tokens); raise "
                + "max_tokens or lower the reasoning effort")
        }
        // A refusal is deterministic and never transient.
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
        return LLMError.failure(.malformedResponse)
    }

}

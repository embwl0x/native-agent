import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared SSE whole-reply collection, credential discovery, prompt blocks and thinking/tool wire controls |

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

    public func requestOutputTokens(model: String) throws -> Int {
        if let limit = LLMCallContext.turnTokenBudget?.available { return limit }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: LLMCallContext.reasoningEffort,
            explicitOverride: maxTokensOverride, providerID: providerId
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
                if index == layout.lastStableIndex { block["cache_control"] = AnthropicOAuthTransport.ephemeralCacheControl }
                return block
            }
        }
        if cacheEligible {
            return [[
                "type": "text",
                "text": sys,
                "cache_control": AnthropicOAuthTransport.ephemeralCacheControl,
            ]]
        }
        // One-shot caller (no chat-turn session bound): skip the breakpoint —
        // the write premium would never be earned back by a read.
        return [[
            "type": "text",
            "text": sys,
        ]]
    }

    /// Whole replies collect the same checked SSE events as a turn.
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools)
    }

    public func completeMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            self.streamMessages(messages: messages, system: system, model: model, tools: tools), using: telemetry)
    }

    // MARK: - Thinking controls

    /// Kimi's declared Think value is sent exactly; unsupported pins are refused.
    func applyThinkingControls(to body: inout [String: Any], model: String) throws {
        guard providerId == "kimi-code", let requested = LLMCallContext.reasoningEffort else { return }
        let effort = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let row = FirstPartyModelCatalog.descriptor(for: model, providerID: providerId),
              row.supportedReasoningEfforts.contains(effort) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model) on Kimi Code. Choose a supported level in Providers.")
        }
        body["reasoning_effort"] = effort
    }

}

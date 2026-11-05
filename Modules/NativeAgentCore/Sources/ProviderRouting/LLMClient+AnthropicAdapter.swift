import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared Messages transport |

public final class AnthropicTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String
    // Transport seams stay module-internal so the separate native-tools file can share them without exposing them publicly.
    let session: URLSession
    let endpoint: URL
    private let apiKeyOverride: String?
    /// Subscription providers sharing the Messages protocol reuse this wire adapter with their own endpoint and credentials.
    private let credentialConfigFile: String
    /// Injected roots confine credentials; secondary runtimes must supply their own root.
    private let dataRootOverride: URL?
    let maxTokensOverride: Int?
    /// First-party identity gates strict schemas, signed thinking and cache markers. Set it once at construction so callers cannot disagree.
    let firstPartyAnthropicToolContract: Bool
    let telemetry: LLMCallTraceRecorder
    /// Thinking replay is memory-only and bounded by tool-call identity.
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
        // Credential discovery and telemetry must share a body so an omitted telemetry override cannot leak traces into the personal root.
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        if let limit = call.turn?.tokenBudget?.available { return limit }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: call.admission?.reasoningEffort,
            explicitOverride: maxTokensOverride, providerID: providerId
        )
    }

    /// One subscription endpoint keeps Kimi Code on the shared Messages wire with its own credential and telemetry identity.
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
            // Kimi shares SSE framing, without first-party strict schemas, signed thinking replay or Anthropic cache markers.
            firstPartyAnthropicToolContract: false
        )
    }

    /// System block texts concatenate byte-for-byte to `system`, with separators on preceding blocks. Valid segments put the cache breakpoint at the stable
    /// end; otherwise the system stays combined. Combined blocks carry a cache breakpoint only for callers with a session context.
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments?,
        cacheEligible: Bool
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
        // One-shot caller (no chat-turn session bound): skip the breakpoint — the write premium would never be earned back by a read.
        return [[
            "type": "text",
            "text": sys,
        ]]
    }

    /// Whole replies collect the same checked SSE events as a turn.
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: call)
    }

    public func completeMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }

    // MARK: - Thinking controls

    /// Kimi's declared Think value is sent exactly; unsupported pins are refused.
    func applyThinkingControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        guard providerId == "kimi-code", let requested = call.admission?.reasoningEffort else { return }
        let effort = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let row = FirstPartyModelCatalog.descriptor(for: model, providerID: providerId),
              row.supportedReasoningEfforts.contains(effort) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model) on Kimi Code. Choose a supported level in Providers.")
        }
        body["reasoning_effort"] = effort
    }

}

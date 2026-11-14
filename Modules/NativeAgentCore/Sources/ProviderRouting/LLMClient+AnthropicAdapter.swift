import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared Messages transport |

public final class AnthropicTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String
    // Transport seams stay module-internal so the separate native-tools file can share them without exposing them publicly.
    let session: URLSession
    let endpoint: URL?
    private let apiKeyOverride: String?
    /// Messages providers reuse this wire adapter with their own endpoint and credentials.
    private let credentialConfigFile: String
    /// Injected roots confine credentials; secondary runtimes must supply their own root.
    private let dataRootOverride: URL?
    let maxTokensOverride: Int?
    /// First-party identity gates key-header auth, strict schemas and conversation cache markers.
    let firstPartyAnthropicToolContract: Bool
    let telemetry: LLMCallTraceRecorder
    /// Thinking replay is memory-only and bounded by tool-call identity.
    let thinkingLedger = ToolCallReplayLedger<AnthropicThinkingRecord>()

    /// Meta's opaque reasoning uses the same Messages blocks and tool-call ledger as Anthropic.
    var replaysThinking: Bool { firstPartyAnthropicToolContract || providerId == "meta" }

    /// Credentials and the route's model list share this root.
    var credentialRoot: URL {
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
        guard let endpoint else {
            throw LLMError.providerError(message: "\(providerId) response endpoint is invalid; correct its provider configuration.")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        if firstPartyAnthropicToolContract {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public init(
        session: URLSession = ProviderHTTP.session,
        endpoint: URL? = URL(string: "https://api.anthropic.com/v1/messages"),
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
        // What is left of a run's budget never exceeds the model's effective ceiling, nor this transport's own cap (Kimi Code's).
        if let allowance = FirstPartyExecutionControls.budgetedOutputTokens(
            model: model, providerID: providerId, call: call, transportCap: maxTokensOverride, dataRoot: credentialRoot) {
            return allowance
        }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: call.admission?.reasoningEffort,
            explicitOverride: maxTokensOverride, providerID: providerId, dataRoot: credentialRoot
        )
    }

    /// One subscription endpoint keeps Kimi Code on the shared Messages wire with its own credential and telemetry identity.
    public static func kimiCode(
        session: URLSession = ProviderHTTP.session,
        apiKeyOverride: String? = nil,
        // Kimi's separate token cap includes its always-on thinking.
        maxTokens: Int = 32_768,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) -> AnthropicTransport {
        AnthropicTransport(
            session: session,
            endpoint: URL(string: "https://api.kimi.com/coding/v1/messages"),
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
        cacheEligible: Bool,
        cacheControl: [String: Any] = AnthropicOAuthTransport.ephemeralCacheControl
    ) -> [[String: Any]]? {
        guard let sys = system, !sys.isEmpty else { return nil }
        if let seg = segments,
           !seg.stable.isEmpty, !seg.dynamic.isEmpty,
           seg.reassembles(into: sys)
        {
            let layout = seg.textBlockLayout
            return layout.texts.enumerated().map { index, text in
                var block: [String: Any] = ["type": "text", "text": text]
                if index == layout.lastStableIndex { block["cache_control"] = cacheControl }
                return block
            }
        }
        if cacheEligible {
            return [[
                "type": "text",
                "text": sys,
                "cache_control": cacheControl,
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

    /// Meta accepts only five-minute cache markers; Anthropic's one-hour TTL is not its wire contract.
    var systemCacheControl: [String: Any] {
        providerId == "meta" ? ["type": "ephemeral", "ttl": "5m"] : AnthropicOAuthTransport.ephemeralCacheControl
    }

    /// Each Messages provider sends its catalog's effort through its documented field.
    func applyThinkingControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        guard providerId == "kimi-code" || providerId == "meta",
              let requested = call.admission?.reasoningEffort else { return }
        let effort = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let row = FirstPartyModelCatalog.descriptor(for: model, providerID: providerId, dataRoot: credentialRoot),
              row.supportedReasoningEfforts.contains(effort) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model) on \(providerId). Choose a supported level in Providers.")
        }
        // "default" is the provider's own default: no thinking or effort field.
        guard effort != "default" else { return }
        if providerId == "meta" {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        } else {
            body["reasoning_effort"] = effort
        }
    }

}

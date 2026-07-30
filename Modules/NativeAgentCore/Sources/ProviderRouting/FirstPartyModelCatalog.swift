import Foundation
import NativeAgentCore
import PersistenceCore

/// Canonical first-party model capabilities used by provider inspection,
/// Mac/iOS/Telegram pickers, preference validation, and request serialization.
///
/// Account-scoped ChatGPT/Codex discovery can override these fallbacks from
/// its signed local cache. Anthropic entries were verified against the live
/// Models API on 2026-07-10; OpenAI and xAI entries follow their current
/// first-party model/capability documentation from the same date.
public struct FirstPartyModelDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let contextLength: Int
    public let supportsStreaming: Bool
    public let supportsVision: Bool
    public let supportsTools: Bool
    public let supportsJSONMode: Bool
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [String]
    public let supportsFast: Bool

    public init(
        id: String,
        name: String,
        contextLength: Int,
        supportsStreaming: Bool = true,
        supportsVision: Bool = true,
        supportsTools: Bool = true,
        supportsJSONMode: Bool = false,
        defaultReasoningEffort: String,
        supportedReasoningEfforts: [String],
        supportsFast: Bool = false
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsJSONMode = supportsJSONMode
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
    }

    public func providerJSON() -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string(name),
            "context_length": .int(Int64(contextLength)),
            "supports_streaming": .bool(supportsStreaming),
            "supports_vision": .bool(supportsVision),
            "supports_tools": .bool(supportsTools),
            "supports_json_mode": .bool(supportsJSONMode),
            "default_reasoning_effort": .string(defaultReasoningEffort),
            "supported_reasoning_efforts": .array(supportedReasoningEfforts.map { .string($0) }),
            "supports_fast": .bool(supportsFast),
        ]
    }
}

public enum FirstPartyModelCatalog {
    public static let publicGPT56Efforts = ["none", "low", "medium", "high", "xhigh", "max"]
    public static let accountGPT56SolTerraEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
    public static let accountGPT56LunaEfforts = ["low", "medium", "high", "xhigh", "max"]
    public static let standardOpenAIEfforts = ["low", "medium", "high", "xhigh"]
    public static let fullClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    public static let claude46Efforts = ["low", "medium", "high", "max"]
    public static let grok45Efforts = ["low", "medium", "high"]

    /// Public OpenAI API catalog. GPT-5.6 uses the public None-through-Max
    /// contract; account-only Ultra is deliberately absent here.
    public static let publicOpenAIModels: [FirstPartyModelDescriptor] = [
        .init(id: "gpt-5.6", name: "GPT-5.6 (Sol alias)", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.4", name: "GPT-5.4", contextLength: 128_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: standardOpenAIEfforts, supportsFast: true),
        .init(id: "gpt-5.4-mini", name: "GPT-5.4 mini", contextLength: 128_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: standardOpenAIEfforts, supportsFast: true),
    ]

    /// Subscription-backed ChatGPT/Codex fallback. A signed models cache
    /// overrides these rows when present, but a transiently incomplete cache
    /// must not erase models that this account has already executed live.
    public static let chatGPTAccountFallbackModels: [FirstPartyModelDescriptor] = [
        .init(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextLength: 372_000, supportsJSONMode: true, defaultReasoningEffort: "low", supportedReasoningEfforts: accountGPT56SolTerraEfforts, supportsFast: true),
        .init(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", contextLength: 372_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: accountGPT56SolTerraEfforts, supportsFast: true),
        .init(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", contextLength: 372_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: accountGPT56LunaEfforts, supportsFast: true),
        .init(id: "gpt-5.4", name: "GPT-5.4", contextLength: 272_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: standardOpenAIEfforts, supportsFast: true),
        .init(id: "gpt-5.4-mini", name: "GPT-5.4 mini", contextLength: 272_000, supportsJSONMode: true, defaultReasoningEffort: "medium", supportedReasoningEfforts: standardOpenAIEfforts, supportsFast: false),
    ]

    /// Current Claude API catalog for the account, including still-available
    /// pinned models. `none` means the model has no adjustable API effort
    /// parameter; it is not sent on the wire.
    public static let anthropicModels: [FirstPartyModelDescriptor] = [
        .init(id: "claude-opus-4-8", name: "Claude Opus 4.8", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: fullClaudeEfforts),
        // Capability/window fields INHERITED verbatim from claude-opus-4-8 and
        // not independently verified for opus-5. Deliberately placed AFTER
        // opus-4-8: index 0 is the implicit provider default via
        // defaultModelForProvider, which must not change here.
        .init(id: "claude-opus-5", name: "Claude Opus 5", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-fable-5", name: "Claude Fable 5", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: claude46Efforts),
        .init(id: "claude-opus-4-6", name: "Claude Opus 4.6", contextLength: 1_000_000, defaultReasoningEffort: "high", supportedReasoningEfforts: claude46Efforts),
        .init(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5", contextLength: 200_000, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high"]),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextLength: 200_000, defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"]),
        .init(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", contextLength: 1_000_000, defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"]),
        .init(id: "claude-opus-4-1-20250805", name: "Claude Opus 4.1", contextLength: 200_000, defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"]),
    ]

    /// xAI text models retained by NativeAgent plus the current Grok 4.5
    /// flagship. Priority processing is supported on xAI text inference.
    public static let xAIModels: [FirstPartyModelDescriptor] = [
        .init(id: "grok-4.5", name: "Grok 4.5", contextLength: 500_000, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: grok45Efforts, supportsFast: true),
        .init(id: "grok-4.20-multi-agent-0309", name: "Grok 4.20 Multi-Agent", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: true),
        .init(id: "grok-4.20-0309-reasoning", name: "Grok 4.20 Reasoning", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"], supportsFast: true),
        .init(id: "grok-4.20-0309-non-reasoning", name: "Grok 4.20 Non-Reasoning", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"], supportsFast: true),
        .init(id: "grok-4.3", name: "Grok 4.3", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"], supportsFast: true),
        .init(id: "grok-build-0.1", name: "Grok Build 0.1", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"], supportsFast: true),
    ]

    /// Moonshot's documented current Kimi baseline. The authenticated
    /// `/v1/models` catalog may add account-visible rows at runtime; these
    /// entries provide conservative context/control truth before that cache
    /// exists and for provider-neutral context budgeting.
    public static let moonshotModels: [FirstPartyModelDescriptor] = [
        .init(id: "kimi-k3", name: "Kimi K3", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max", supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.7-code-highspeed", name: "Kimi K2.7 Code Highspeed", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "max", supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "max", supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.6", name: "Kimi K2.6", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["none", "high"]),
    ]

    /// Kimi Code SUBSCRIPTION catalog (provider id "kimi-code"). Distinct from
    /// `moonshotModels` (the token-billed developer API): these ids speak the
    /// ANTHROPIC protocol at api.kimi.com/coding and are billed by the Kimi
    /// Code subscription. The list is a tier-SUPERSET — the server rejects the
    /// tiers this account can't reach — so there is no live /models endpoint to
    /// cache; this static catalog is the single source of truth. `k3`'s window
    /// is the documented 1,048,576; the coding models use 262,144.
    public static let kimiCodeModels: [FirstPartyModelDescriptor] = [
        // Kimi's real reasoning contract (live-probed 2026-07-19): top-level
        // reasoning_effort with low/high/max on every model; thinking is
        // ALWAYS on and cannot be disabled, so "none" is not offered — it
        // would lie. Defaults: k3 "max" (Kimi's own documented default when
        // the field is omitted); the coding pair "high" (their point is
        // speed-balanced coding; max is one pick away).
        .init(id: "kimi-for-coding", name: "Kimi for Coding", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "k3", name: "Kimi K3", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max", supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "kimi-for-coding-highspeed", name: "Kimi for Coding (Highspeed)", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "high", "max"]),
    ]

    /// Exact ids that belong to the "kimi-code" subscription provider. Used by
    /// inferProvider/routing so `kimi-for-coding`, `kimi-for-coding-highspeed`
    /// and bare `k3` classify to kimi-code even though they'd otherwise match
    /// the `kimi-` prefix that routes to moonshot. Moonshot's own ids
    /// (`kimi-k2*`, `kimi-latest`, `kimi-k3`) are NOT in this set.
    public static let kimiCodeModelIDSet: Set<String> = Set(kimiCodeModels.map { $0.id })

    public static func descriptor(for modelID: String) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Provider-neutral context budgeting must be conservative when the
        // same model id has different public/account windows. Provider pickers
        // still use their exact catalog; this lookup chooses the smallest
        // verified window so Fluid Context cannot overfill either transport.
        return (publicOpenAIModels + chatGPTAccountFallbackModels + anthropicModels + xAIModels + moonshotModels + kimiCodeModels)
            .filter { $0.id.lowercased() == id }
            .min { $0.contextLength < $1.contextLength }
    }

    /// Exact first-party capability lookup for a selected transport. The same
    /// model id can have different account/public controls, so command surfaces
    /// must not use the provider-neutral context-budget lookup above.
    public static func descriptor(
        for modelID: String,
        providerID: String
    ) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let models: [FirstPartyModelDescriptor]
        switch provider {
        case "openai":
            models = publicOpenAIModels
        case "codex", "openai_oauth_direct":
            models = chatGPTAccountFallbackModels
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp":
            models = anthropicModels
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            models = xAIModels
        case "moonshot", "kimi":
            models = moonshotModels
        case "kimi-code":
            models = kimiCodeModels
        default:
            return descriptor(for: id)
        }
        return models.first { $0.id.lowercased() == id }
    }

    public static func anthropicDescriptor(for modelID: String) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return anthropicModels.first { $0.id.lowercased() == id }
    }

    public static func xAIDescriptor(for modelID: String) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return xAIModels.first { $0.id.lowercased() == id }
    }
}

/// Provider-specific request controls. A picker capability is not considered
/// implemented until the corresponding adapter emits it here.
public enum FirstPartyExecutionControls {
    /// `max_tokens` is a hard ceiling over Claude's complete output,
    /// including adaptive thinking, visible text, and tool arguments. A
    /// 4,096-token ceiling is therefore not a conservative chat default for
    /// current reasoning models: a substantive build turn can spend the whole
    /// allowance thinking and never reach its first tool call. Keep explicit
    /// constructor overrides exact for tests/specialized callers; production
    /// defaults follow the selected model and effort without lowering the
    /// user's chosen reasoning level.
    public static func anthropicMaxOutputTokens(
        model: String,
        requestedEffort: String?,
        explicitOverride: Int?
    ) -> Int {
        if let explicitOverride {
            return max(1, explicitOverride)
        }
        guard let descriptor = FirstPartyModelCatalog.anthropicDescriptor(for: model) else {
            return 16_384
        }
        let requested = requestedEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let effort = requested.flatMap {
            descriptor.supportedReasoningEfforts.contains($0) ? $0 : nil
        } ?? descriptor.defaultReasoningEffort
        switch effort {
        case "xhigh", "max":
            return 65_536
        case "high":
            return descriptor.supportedReasoningEfforts.contains("xhigh")
                || descriptor.supportedReasoningEfforts.contains("max")
                ? 65_536
                : 32_768
        case "medium":
            return 32_768
        case "low":
            return 16_384
        default:
            // Pinned non-adaptive models do not spend the ceiling on hidden
            // reasoning, but builder tool arguments still need more than the
            // historical 4k response cap.
            return 8_192
        }
    }

    public static func anthropicEmptyStreamError(
        providerID: String,
        stopReason: String?,
        expectedOutput: String
    ) -> LLMError {
        let reason = stopReason ?? "absent"
        if reason == "max_tokens" {
            return .providerError(message:
                "\(providerID): thinking consumed the entire max_tokens budget "
                + "before any \(expectedOutput) (stop_reason=max_tokens); raise "
                + "max_tokens or lower the reasoning effort")
        }
        if reason == "refusal" {
            return .providerError(message:
                "\(providerID): model declined to answer (stop_reason=refusal)")
        }
        return .transient(message:
            "\(providerID): stream completed with no \(expectedOutput) "
            + "(stop_reason=\(reason))")
    }

    public static func anthropicEffort(model: String, requested: String?) -> String? {
        guard let descriptor = FirstPartyModelCatalog.anthropicDescriptor(for: model),
              let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "none", descriptor.supportedReasoningEfforts.contains(normalized) else {
            return nil
        }
        return normalized
    }

    public static func applyAnthropicControls(to body: inout [String: Any], model: String) {
        guard let effort = anthropicEffort(model: model, requested: LLMCallContext.reasoningEffort) else {
            return
        }
        var outputConfig = body["output_config"] as? [String: Any] ?? [:]
        outputConfig["effort"] = effort
        body["output_config"] = outputConfig
    }

    public static func xAIReasoningEffort(model: String, requested: String?) -> String? {
        guard let descriptor = FirstPartyModelCatalog.xAIDescriptor(for: model),
              let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "none",
              descriptor.supportedReasoningEfforts.count > 1,
              descriptor.supportedReasoningEfforts.contains(normalized) else {
            return nil
        }
        return normalized
    }

    public static func applyXAIControls(to body: inout [String: Any], model: String) {
        if let effort = xAIReasoningEffort(model: model, requested: LLMCallContext.reasoningEffort) {
            body["reasoning_effort"] = effort
        }
        let tier = LLMCallContext.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if tier == "priority" || tier == "fast",
           FirstPartyModelCatalog.xAIDescriptor(for: model)?.supportsFast == true {
            body["service_tier"] = "priority"
        }
    }
}

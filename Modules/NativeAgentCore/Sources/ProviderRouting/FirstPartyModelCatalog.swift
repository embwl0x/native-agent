import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `FirstPartyModelCatalog.swift` | `FirstPartyModelCatalog`: route-owned model contracts |

/// One route-specific catalog keeps pickers, validation and serialization aligned; account discovery owns account-scoped rows.
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
    /// Mid-conversation system support is distinct from the turn's user-leading context block.
    public let supportsMidConversationSystem: Bool
    /// Anthropic adaptive thinking; the pinned 4.5 rows predate it.
    public let adaptiveThinking: Bool
    /// The public OpenAI API serves this model through Responses, not Chat Completions.
    public let usesResponses: Bool
    public let reasoningWire: ReasoningWire

    public enum ReasoningWire: Sendable, Equatable {
        case effort
        /// Binary thinking disables only at none.
        case thinkingSwitch
    }

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
        supportsFast: Bool = false,
        supportsMidConversationSystem: Bool = false,
        adaptiveThinking: Bool = true,
        usesResponses: Bool = false,
        reasoningWire: ReasoningWire = .effort
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
        self.supportsMidConversationSystem = supportsMidConversationSystem
        self.adaptiveThinking = adaptiveThinking
        self.usesResponses = usesResponses
        self.reasoningWire = reasoningWire
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
            "supports_mid_conversation_system": .bool(supportsMidConversationSystem),
        ]
    }
}

public enum FirstPartyModelCatalog {
    public static let gpt6AstraModelID = "gpt-6-astra"
    public static let publicGPT6AstraEfforts = ["low", "medium", "high", "xhigh", "max"]
    public static let publicGPT56Efforts = ["none", "low", "medium", "high", "xhigh", "max"]
    public static let fullClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    public static let claude46Efforts = ["low", "medium", "high", "max"]
    public static let grok45Efforts = ["low", "medium", "high"]

    /// Public GPT-6 requests require Responses.
    public static let publicOpenAIModels: [FirstPartyModelDescriptor] = [
        .init(id: "gpt-5.6", name: "GPT-5.6 (Sol alias)", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", contextLength: 400_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true),
        .init(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", contextLength: 1_050_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT6AstraEfforts, supportsFast: true, usesResponses: true),
        // Terra's 1.05M window allows 922K input and 128K output.
        .init(id: "gpt-6.1-terra", name: "GPT-6.1-Terra", contextLength: 1_050_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true, usesResponses: true),
        .init(id: "gpt-6-sol", name: "GPT-6-Sol", contextLength: 1_050_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true, usesResponses: true),
        .init(id: gpt6AstraModelID, name: "GPT-6-Astra", contextLength: 1_050_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT6AstraEfforts, supportsFast: true, usesResponses: true),
        .init(id: "gpt-6-luna", name: "GPT-6-Luna", contextLength: 1_050_000, supportsJSONMode: true, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: publicGPT56Efforts, supportsFast: true, usesResponses: true),
    ]

    public static let anthropicModels: [FirstPartyModelDescriptor] = [
        // The first row becomes a new account's saved default. Opus requires thinking and rejects forced tools; Sonnet capability flags follow Sonnet 5
        // without independent verification.
        .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", contextLength: 1_000_000, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", contextLength: 1_000_000, defaultReasoningEffort: "medium",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        .init(id: "claude-opus-4-8", name: "Claude Opus 4.8", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        // Fable 5.2 keeps Fable 5.1's request contract and rejects a replayed thinking block whose system, tools or earlier messages changed.
        .init(id: "claude-fable-5-2", name: "Claude Fable 5.2", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        // Fable 5.1 allows 128K output and requires adaptive thinking without explicit budgets, forced tools or prefill.
        .init(id: "claude-fable-5-1", name: "Claude Fable 5.1", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        // Capability/window fields INHERITED verbatim from claude-opus-4-8 and not independently verified for opus-5.
        .init(id: "claude-opus-5", name: "Claude Opus 5", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        .init(id: "claude-fable-5", name: "Claude Fable 5", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts, supportsMidConversationSystem: true),
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: fullClaudeEfforts),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: claude46Efforts),
        .init(id: "claude-opus-4-6", name: "Claude Opus 4.6", contextLength: 1_000_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: claude46Efforts),
        .init(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5", contextLength: 200_000, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "medium", "high"], adaptiveThinking: false),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextLength: 200_000, defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"],
            adaptiveThinking: false),
        .init(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", contextLength: 200_000, defaultReasoningEffort: "none",
            supportedReasoningEfforts: ["none"], adaptiveThinking: false),
    ]

    /// Priority processing applies to xAI text inference.
    public static let xAIModels: [FirstPartyModelDescriptor] = [
        .init(id: "grok-4.7", name: "Grok 4.7", contextLength: 500_000, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: true),
        .init(id: "grok-4.6", name: "Grok 4.6", contextLength: 500_000, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: true),
        .init(id: "grok-4.5", name: "Grok 4.5", contextLength: 500_000, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: grok45Efforts, supportsFast: true),
        .init(id: "grok-4.20-multi-agent-0309", name: "Grok 4.20 Multi-Agent", contextLength: 1_000_000, supportsJSONMode: true,
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: true),
        .init(id: "grok-4.20-0309-reasoning", name: "Grok 4.20 Reasoning", contextLength: 1_000_000, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["high"], supportsFast: true),
        .init(id: "grok-4.20-0309-non-reasoning", name: "Grok 4.20 Non-Reasoning", contextLength: 1_000_000, supportsJSONMode: true,
            defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"], supportsFast: true),
        .init(id: "grok-4.3", name: "Grok 4.3", contextLength: 1_000_000, supportsJSONMode: true, defaultReasoningEffort: "low",
            supportedReasoningEfforts: ["none", "low", "medium", "high", "xhigh"], supportsFast: true),
        .init(id: "grok-build-0.1", name: "Grok Build 0.1", contextLength: 256_000, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["high"], supportsFast: true),
    ]

    /// Shipped Moonshot rows provide conservative context/control evidence before authenticated discovery; the live catalog may add account-visible rows.
    public static let moonshotModels: [FirstPartyModelDescriptor] = [
        // Kimi K3.1 Pro uses top-level reasoning_effort with always-on thinking.
        .init(id: "kimi-k3.1-pro", name: "Kimi K3.1 Pro", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "kimi-k3.1-pro-highspeed", name: "Kimi K3.1 Pro Highspeed", contextLength: 1_048_576, supportsJSONMode: true,
            defaultReasoningEffort: "max", supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "kimi-k3", name: "Kimi K3", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.7-code-highspeed", name: "Kimi K2.7 Code Highspeed", contextLength: 262_144, supportsJSONMode: true,
            defaultReasoningEffort: "max", supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["max"]),
        .init(id: "kimi-k2.6", name: "Kimi K2.6", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["none", "high"], reasoningWire: .thinkingSwitch),
    ]

    /// Kimi Code uses the subscription Anthropic endpoint, distinct from Moonshot billing. With no live models endpoint, this tier-superset catalog owns
    /// IDs; the server enforces entitlement.
    public static let kimiCodeModels: [FirstPartyModelDescriptor] = [
        // Kimi uses top-level reasoning_effort low/high/max with always-on thinking.
        .init(id: "kimi-for-coding", name: "Kimi for Coding", contextLength: 262_144, supportsJSONMode: true, defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "high", "max"]),
        // K3.1 Pro requires Plus; 1M context and Highspeed require Pro.
        .init(id: "k3.1-pro", name: "Kimi K3.1 Pro", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "k3.1-pro-highspeed", name: "Kimi K3.1 Pro (Highspeed)", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["low", "high", "max"]),
        .init(id: "k3", name: "Kimi K3", contextLength: 1_048_576, supportsJSONMode: true, defaultReasoningEffort: "max", supportedReasoningEfforts: ["low",
            "high", "max"]),
        .init(id: "kimi-for-coding-highspeed", name: "Kimi for Coding (Highspeed)", contextLength: 262_144, supportsJSONMode: true,
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "high", "max"]),
    ]

    /// Exact subscription IDs must resolve before Moonshot classification; Moonshot's own IDs stay outside this set.
    public static let kimiCodeModelIDSet: Set<String> = Set(kimiCodeModels.map { $0.id })

    /// Standard pay-as-you-go models; Contributor mode requires a separate data-use choice.
    public static let metaModels: [FirstPartyModelDescriptor] = [
        // The Messages wire declares low through xhigh; its history accepts user/assistant roles only.
        .init(id: "muse-wonder-1.0", name: "Muse Wonder 1.0", contextLength: 1_048_576, supportsJSONMode: true,
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]),
        .init(id: "muse-spark-1.3", name: "Muse Spark 1.3", contextLength: 1_048_576, supportsJSONMode: true,
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]),
    ]

    public static func descriptor(for modelID: String) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Provider-neutral context budgeting must be conservative when the same model id has different public/account windows. Provider pickers still use
        // their exact catalog; this lookup chooses the smallest verified window so Fluid Context cannot overfill either transport.
        return (publicOpenAIModels + anthropicModels + xAIModels + moonshotModels + kimiCodeModels + metaModels)
            .filter { $0.id.lowercased() == id }
            .min { $0.contextLength < $1.contextLength }
    }

    /// Exact first-party capability lookup for a selected transport. The same model id can have different account/public controls, so command surfaces must
    /// not use the provider-neutral context-budget lookup above.
    public static func descriptor(
        for modelID: String,
        providerID: String
    ) -> FirstPartyModelDescriptor? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let models = self.models(forProviderID: provider)
        return models.first { $0.id.lowercased() == id }
    }

    /// Shipped route catalogs are data; fetched routes return no fixed rows here.
    public static func models(forProviderID providerID: String) -> [FirstPartyModelDescriptor] {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai": return publicOpenAIModels
        case "codex", "openai_oauth_direct": return []
        case "anthropic", "anthropic_oauth_direct": return anthropicModels
        case "xai_oauth_direct":
            return xAIModels
        case "moonshot": return moonshotModels
        case "kimi-code": return kimiCodeModels
        case "meta": return metaModels
        default: return []
        }
    }

    /// Absent non-text capabilities must be refused by callers.
    public struct FirstPartyImageRoute: Sendable, Equatable {
        public let backend: String
        /// The requested image model does not prove which model generated an image.
        public let model: String
        public init(backend: String, model: String) {
            self.backend = backend
            self.model = model
        }
    }

    /// A route without an image API refuses generation rather than borrowing another backend.
    public static func imageRoute(forProviderID providerID: String) -> FirstPartyImageRoute? {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai": return FirstPartyImageRoute(backend: "openai_api", model: "gpt-image-2")
        case "codex", "openai_oauth_direct":
            return FirstPartyImageRoute(backend: "codex", model: "gpt-image-2")
        default: return nil
        }
    }

    /// Only the billed platform route sells speech; subscription routes refuse cloud voice and explain why.
    public static func speechModel(forProviderID providerID: String) -> String? {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai": return "tts-1"
        default: return nil
        }
    }

    /// Saved picks are checked against their route's shipped catalog without literal replacements. Routes with fetched catalogs are not second-guessed
    /// here.
    public static func routeCarries(_ modelID: String, providerID: String?) -> Bool {
        guard let providerID else { return true }
        let catalog = models(forProviderID: providerID)
        guard !catalog.isEmpty else { return true }
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.contains { $0.id.lowercased() == id }
    }

    /// Missing catalog evidence leaves supported efforts unknown.
    public static func routeSupportedEfforts(
        _ modelID: String,
        providerID: String
    ) -> [String]? {
        let catalog = models(forProviderID: providerID)
        guard !catalog.isEmpty else { return nil }
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.first { $0.id.lowercased() == id }?.supportedReasoningEfforts
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

/// Provider-specific request controls. A picker capability is not considered implemented until the corresponding adapter emits it here.
public enum FirstPartyExecutionControls {
    /// The output ceiling includes thinking and tool arguments; defaults must leave room to act without lowering the selected effort. Explicit caller caps
    /// stay exact.
    public static func anthropicMaxOutputTokens(
        model: String,
        requestedEffort: String?,
        explicitOverride: Int?,
        providerID: String = "anthropic"
    ) throws -> Int {
        if let explicitOverride {
            return max(1, explicitOverride)
        }
        guard let descriptor = FirstPartyModelCatalog.descriptor(for: model, providerID: providerID) else {
            throw LLMError.providerError(message: "Output budget for \(model) on \(providerID) is unknown. Refresh Providers and select a catalog model.")
        }
        let requested = requestedEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let requested, !descriptor.supportedReasoningEfforts.contains(requested) {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model). Choose a supported level in Providers.")
        }
        let effort = requested ?? descriptor.defaultReasoningEffort
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
            // Non-adaptive models still need room for builder tool arguments.
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
            return .outputLengthLimit(partial: "")
        }
        if reason == "refusal" {
            return .providerError(message:
                "\(providerID): model declined to answer (stop_reason=refusal)")
        }
        return .underlying(message:
            "\(providerID): stream completed with no \(expectedOutput) "
            + "(stop_reason=\(reason))")
    }

    public static func anthropicEffort(model: String, requested: String?) throws -> String? {
        guard let requested else { return nil }
        guard let descriptor = FirstPartyModelCatalog.anthropicDescriptor(for: model) else {
            throw LLMError.providerError(message: "Think controls for \(model) are unknown. Choose a catalog model in Providers.")
        }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard descriptor.supportedReasoningEfforts.contains(normalized) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model). Choose a supported level in Providers.")
        }
        return normalized == "none" ? nil : normalized
    }

    public static func applyAnthropicControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        if FirstPartyModelCatalog.anthropicDescriptor(for: model)?.adaptiveThinking == true {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        guard let effort = try anthropicEffort(model: model, requested: call.admission?.reasoningEffort) else {
            return
        }
        var outputConfig = body["output_config"] as? [String: Any] ?? [:]
        outputConfig["effort"] = effort
        body["output_config"] = outputConfig
    }

    public static func xAIReasoningEffort(model: String, requested: String?) throws -> String? {
        guard let requested else { return nil }
        guard let descriptor = FirstPartyModelCatalog.xAIDescriptor(for: model) else {
            throw LLMError.providerError(message: "xAI Think controls for \(model) are unknown. Choose a catalog model in Providers.")
        }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard descriptor.supportedReasoningEfforts.contains(normalized) else {
            throw LLMError.providerError(message: "Think level '\(requested)' is unsupported for \(model) on xAI. Choose a supported level in Providers.")
        }
        guard normalized != "none", descriptor.supportedReasoningEfforts.count > 1 else { return nil }
        return normalized
    }

    public static func applyXAIControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        if let effort = try xAIReasoningEffort(model: model, requested: call.admission?.reasoningEffort) {
            body["reasoning_effort"] = effort
        }
        let tier = call.admission?.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let tier, tier != "default" {
            guard tier == "priority", FirstPartyModelCatalog.xAIDescriptor(for: model)?.supportsFast == true else {
                throw LLMError.providerError(message: "Service tier '\(tier)' is unsupported for \(model) on xAI. Choose a supported tier in Providers.")
            }
            body["service_tier"] = "priority"
        }
    }
}

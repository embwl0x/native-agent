import Foundation
import NativeAgentCore

// Blueprint: | `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: transport-specific catalog capability admission and reasoning/service-tier wire serialization |

/// Capability-aware controls for public OpenAI requests and ChatGPT/Codex
/// account-backed requests. A signed account catalog can expose reasoning
/// levels that are not valid public API values, so those contracts stay
/// transport-specific.
public enum OpenAIExecutionControls {
    public enum Transport {
        case publicAPI
        case chatGPTOAuth
        case codexCLI

        /// The route whose catalog rows declare what this transport accepts.
        var route: String {
            switch self {
            case .publicAPI: "openai"
            case .chatGPTOAuth: "openai_oauth_direct"
            case .codexCLI: "codex"
            }
        }
    }

    private static let standardEfforts: Set<String> = ["low", "medium", "high", "xhigh"]

    /// Models intentionally exposed by the model-facing Codex bridge tools.
    /// The parser remains open to account-discovered models for compatibility;
    /// these are the built-in choices advertised to the model.
    public static let codexBridgeModelIDs = FirstPartyModelCatalog.chatGPTAccountFallbackModels.map(\.id)

    /// The efforts the transport's catalog row declares for the model; a model
    /// no row carries takes the standard set, whatever its spelling.
    public static func supportedReasoningEfforts(
        model: String,
        transport: Transport = .publicAPI
    ) -> Set<String> {
        FirstPartyModelCatalog.routeSupportedEfforts(model, providerID: transport.route).map(Set.init) ?? standardEfforts
    }

    static func usesResponses(model: String) -> Bool {
        FirstPartyModelCatalog.descriptor(for: model, providerID: Transport.publicAPI.route)?.usesResponses == true
    }

    public static func reasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil
    ) -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supported = supportedEfforts.map { Set($0) }
            ?? supportedReasoningEfforts(model: model, transport: transport)
        return supported.contains(normalized)
            ? normalized
            : nil
    }

    /// Convert a selectable account tier into the exact value accepted by the
    /// target request transport. `max` and `ultra` are Codex client presets;
    /// the direct ChatGPT Responses backend exposes the same deepest wire
    /// effort as `xhigh` and rejects either preset when sent literally. Codex
    /// CLI keeps the original value so it can apply its client-side preset
    /// behavior, including Ultra's orchestration policy.
    public static func wireReasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil
    ) -> String? {
        guard let selected = reasoningEffort(
            model: model,
            requested: requested,
            transport: transport,
            supportedEfforts: supportedEfforts
        ) else { return nil }
        if transport == .chatGPTOAuth,
           selected == "max" || selected == "ultra" {
            return "xhigh"
        }
        return selected
    }

    /// Priority only where the model's row declares Fast: the account's own
    /// row when the caller has it, else the transport's shipped row.
    public static func serviceTier(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI,
        supportsFast: Bool? = nil
    ) -> String? {
        guard supportsFast ?? FirstPartyModelCatalog.descriptor(
            for: model, providerID: transport.route)?.supportsFast == true else { return nil }
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "priority" || normalized == "fast" else { return nil }
        return "priority"
    }

    static func applyResponsesControls(
        to body: inout [String: Any],
        model: String,
        transport: Transport = .publicAPI,
        supportedEfforts: [String]? = nil,
        supportsFast: Bool? = nil
    ) {
        if let effort = wireReasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort,
            transport: transport,
            supportedEfforts: supportedEfforts
        ) {
            body["reasoning"] = ["effort": effort]
        }
        // Opt in even when the provider chooses its default reasoning effort.
        // Summary frames renew the guard but never become answer/code content.
        if ProviderStreamContext.stallOnly {
            var reasoning = body["reasoning"] as? [String: String] ?? [:]
            reasoning["summary"] = "auto"
            body["reasoning"] = reasoning
        }
        if let tier = serviceTier(
            model: model,
            requested: LLMCallContext.serviceTier,
            transport: transport,
            supportsFast: supportsFast
        ) {
            body["service_tier"] = tier
        }
    }

    static func applyChatCompletionsControls(to body: inout [String: Any], model: String) {
        if let effort = wireReasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort
        ) {
            body["reasoning_effort"] = effort
        }
        if let tier = serviceTier(model: model, requested: LLMCallContext.serviceTier) {
            body["service_tier"] = tier
        }
    }
}

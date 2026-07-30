import Foundation
import NativeAgentCore

/// Capability-aware controls for public OpenAI requests and ChatGPT/Codex
/// account-backed requests. A signed account catalog can expose reasoning
/// levels that are not valid public API values, so those contracts stay
/// transport-specific.
public enum OpenAIExecutionControls {
    public enum Transport {
        case publicAPI
        case chatGPTOAuth
        case codexCLI
    }

    private static let standardEfforts: Set<String> = ["low", "medium", "high", "xhigh"]
    private static let publicGPT56Efforts: Set<String> = ["none", "low", "medium", "high", "xhigh", "max"]
    private static let accountSolTerraEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let accountLunaEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    public static func supportedReasoningEfforts(
        model: String,
        transport: Transport = .publicAPI
    ) -> Set<String> {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch transport {
        case .publicAPI:
            if normalizedModel == "gpt-5.6" || normalizedModel.hasPrefix("gpt-5.6-") {
                return publicGPT56Efforts
            }
            return standardEfforts
        case .chatGPTOAuth, .codexCLI:
            switch normalizedModel {
            case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra": return accountSolTerraEfforts
            case "gpt-5.6-luna": return accountLunaEfforts
            default: return standardEfforts
            }
        }
    }

    public static func reasoningEffort(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI
    ) -> String? {
        guard let requested else { return nil }
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedReasoningEfforts(model: model, transport: transport).contains(normalized)
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
        transport: Transport = .publicAPI
    ) -> String? {
        guard let selected = reasoningEffort(
            model: model,
            requested: requested,
            transport: transport
        ) else { return nil }
        if transport == .chatGPTOAuth,
           selected == "max" || selected == "ultra" {
            return "xhigh"
        }
        return selected
    }

    public static func serviceTier(
        model: String,
        requested: String?,
        transport: Transport = .publicAPI
    ) -> String? {
        guard model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("gpt-") else { return nil }
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "priority" || normalized == "fast" else { return nil }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel == "gpt-5.4-mini" {
            switch transport {
            case .publicAPI: break
            case .chatGPTOAuth, .codexCLI: return nil
            }
        }
        return "priority"
    }

    static func applyResponsesControls(
        to body: inout [String: Any],
        model: String,
        transport: Transport = .publicAPI
    ) {
        if let effort = wireReasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort,
            transport: transport
        ) {
            body["reasoning"] = ["effort": effort]
        }
        if let tier = serviceTier(
            model: model,
            requested: LLMCallContext.serviceTier,
            transport: transport
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

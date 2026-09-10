import Foundation
import NativeAgentCore

/// Transport capability, independent of the selected model's catalog claims.
public enum ProviderToolCapability {
    public static func supportsTools(providerID: String) -> Bool {
        switch providerID {
        case "anthropic", "kimi-code": AnthropicAdapter.supportsTools
        case "anthropic_oauth_direct": AnthropicOAuthDirectAdapter.supportsTools
        case "openai": OpenAIAdapter.supportsTools
        case "openai_oauth_direct": OpenAIOAuthDirectAdapter.supportsTools
        case "openrouter": OpenRouterAdapter.supportsTools
        case "moonshot": MoonshotAdapter.supportsTools
        case "xai_oauth_direct": XAIOAuthDirectAdapter.supportsTools
        case "codex": CodexAdapter.supportsTools
        default: false
        }
    }

    public static func caption(providerID: String) -> String? {
        supportsTools(providerID: providerID) ? nil : "text only, no tools"
    }

    /// Said to the model before its brief on an account that cannot call tools.
    public static let textOnlyTurnPreface = "Note: this account cannot use tools in NativeAgent, so nothing can be read, fetched or checked in this turn. Begin the reply by saying so plainly, and never present remembered or earlier text as freshly observed."

    public static let unavailableNote = "This account cannot use tools in NativeAgent; choose ChatGPT (OAuth) or another account for tasks that read pages or files."

    static func recordOfferedTools(providerID: String, tools: [LLMToolSchema]?) {
        if tools?.isEmpty == false, !supportsTools(providerID: providerID) {
            LLMCallContext.toolCapabilityNote?(unavailableNote)
        }
    }
}

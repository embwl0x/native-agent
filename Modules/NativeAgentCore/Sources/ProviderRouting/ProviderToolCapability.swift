import Foundation
import NativeAgentCore

// Blueprint: | `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared tool/image transport capabilities independent of model-name inference |

/// How a transport carries tools. Each adapter declares its own; nothing
/// decides it from a provider's name.
public enum ProviderToolWire: Sendable, Equatable {
    /// A `tools` array on the request, calls back as structured events.
    case native
    /// The catalog as prose, calls as markers in the reply. The Claude
    /// subscription rejects a request body that carries `tools`.
    case textMarkers
    /// The transport carries no NativeAgent tools.
    case unsupported
}

/// Transport capability, independent of the selected model's catalog claims:
/// the route id names its adapter, and the adapter's declarations answer.
public enum ProviderToolCapability {
    static func transport(providerID: String) -> (any LLMTransport.Type)? {
        switch providerID {
        case "anthropic", "kimi-code": AnthropicTransport.self
        case "anthropic_oauth_direct": AnthropicOAuthTransport.self
        case "openai": OpenAITransport.self
        case "openai_oauth_direct": ChatGPTTransport.self
        case "openrouter": OpenRouterTransport.self
        case "moonshot": MoonshotTransport.self
        case "xai_oauth_direct": XAIOAuthTransport.self
        case "codex": CodexProcess.self
        default: nil
        }
    }

    public static func wire(providerID: String) -> ProviderToolWire {
        transport(providerID: providerID)?.toolWire ?? .unsupported
    }

    public static func supportsTools(providerID: String) -> Bool {
        wire(providerID: providerID) != .unsupported
    }

    /// Whether the route's transport puts an image in front of the model.
    public static func carriesImages(providerID: String) -> Bool {
        transport(providerID: providerID)?.carriesImages ?? false
    }

    public static func caption(providerID: String) -> String? {
        supportsTools(providerID: providerID) ? nil : "text only, no tools"
    }

    public static let unavailableNote = "This account cannot use tools in NativeAgent; choose ChatGPT (OAuth) or another account for tasks that read pages or files."

    static func recordOfferedTools(providerID: String, tools: [LLMToolSchema]?) {
        if tools?.isEmpty == false, !supportsTools(providerID: providerID) {
            LLMCallContext.toolCapabilityNote?(unavailableNote)
        }
    }
}

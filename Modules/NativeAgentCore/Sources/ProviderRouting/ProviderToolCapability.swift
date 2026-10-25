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
    static func transport(providerID: String) -> (any LLMAdapter.Type)? {
        switch providerID {
        case "anthropic", "kimi-code": AnthropicAdapter.self
        case "anthropic_oauth_direct": AnthropicOAuthDirectAdapter.self
        case "openai": OpenAIAdapter.self
        case "openai_oauth_direct": OpenAIOAuthDirectAdapter.self
        case "openrouter": OpenRouterAdapter.self
        case "moonshot": MoonshotAdapter.self
        case "xai_oauth_direct": XAIOAuthDirectAdapter.self
        case "codex": CodexAdapter.self
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

    /// Said to the model before its brief on an account that cannot call tools.
    public static let textOnlyTurnPreface = "Note: this account cannot use tools in NativeAgent, so nothing can be read, fetched or checked in this turn. Begin the reply by saying so plainly, and never present remembered or earlier text as freshly observed."

    public static let unavailableNote = "This account cannot use tools in NativeAgent; choose ChatGPT (OAuth) or another account for tasks that read pages or files."

    static func recordOfferedTools(providerID: String, tools: [LLMToolSchema]?) {
        if tools?.isEmpty == false, !supportsTools(providerID: providerID) {
            LLMCallContext.toolCapabilityNote?(unavailableNote)
        }
    }
}

/// The text-marker codec's question, answered by the declared wire.
public enum NativeToolCapability {
    public static func providerSupportsNativeTools(_ providerId: String?) -> Bool {
        providerId.map { ProviderToolCapability.wire(providerID: $0) == .native } ?? false
    }
}

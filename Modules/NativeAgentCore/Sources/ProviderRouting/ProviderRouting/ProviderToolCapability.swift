import Foundation
import NativeAgentCore

// Blueprint: | `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared wire grammar |

/// How a transport carries tools. Each adapter declares its own; nothing decides it from a provider's name.
public enum ProviderToolWire: Sendable, Equatable {
    /// A `tools` array on the request, calls back as structured events.
    case native
    /// The catalog as prose, calls as markers in the reply. The Claude subscription rejects a request body that carries `tools`.
    case textMarkers
    /// The transport carries no NativeAgent tools.
    case unsupported
}

public protocol ProviderTransportCapabilities: Sendable {
    static var toolWire: ProviderToolWire { get }
    static var carriesImages: Bool { get }
}

extension ProviderTransportCapabilities {
    public static var carriesImages: Bool { true }
}

extension CodexProcess: ProviderTransportCapabilities {}

/// Transport capability, independent of the selected model's catalog claims: the route id names its adapter, and the adapter's declarations answer.
public enum ProviderToolCapability {
    static func transport(providerID: String) -> (any ProviderTransportCapabilities.Type)? {
        ProviderRegistry.profiles.first { $0.id == providerID }?.capabilities
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

    public static let unavailableNote = """
        This account cannot use tools in NativeAgent; choose ChatGPT (OAuth) or another account for tasks that read \
        pages or files.
        """

    static func recordOfferedTools(providerID: String, tools: [LLMToolSchema]?, call: LLMCall) {
        if tools?.isEmpty == false, !supportsTools(providerID: providerID) {
            call.turn?.capabilityNote?(unavailableNote)
        }
    }
}

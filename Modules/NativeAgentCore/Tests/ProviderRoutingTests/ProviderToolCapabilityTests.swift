import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

@Suite struct ProviderToolCapabilityTests {
    @Test func everyAdapterDeclaresToolCapability() {
        let adapters: [(any LLMAdapter, Bool)] = [
            (AnthropicAdapter(), true),
            (AnthropicAdapter(providerId: "kimi-code"), true),
            (AnthropicOAuthDirectAdapter(), true),
            (OpenAIAdapter(), true),
            (OpenAIOAuthDirectAdapter(), true),
            (OpenRouterAdapter(), true),
            (MoonshotAdapter(), true),
            (XAIOAuthDirectAdapter(), true),
            (CodexAdapter(), false),
        ]
        for (adapter, expected) in adapters {
            #expect(adapter.supportsTools == expected, "\(adapter.providerId)")
            #expect(ProviderToolCapability.supportsTools(providerID: adapter.providerId) == expected)
        }
        #expect(!ProviderToolCapability.supportsTools(providerID: "unknown"))
    }
}

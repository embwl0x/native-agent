import Testing
@testable import ChatOrchestration

// gpt-5.5 review HIGH (kimi-code provider, 2026-07-18): the API-key
// AnthropicAdapter never sends native tools[], so Kimi Code subscription
// models are tool-capable ONLY via the text-compat path's system-block tool
// contract. These pin the routing that makes that true — and that moonshot's
// own kimi-* ids do NOT get pulled onto the Anthropic text-compat path.
struct KimiCodeTextCompatRoutingTests {
    @Test func kimiCodeModelsRouteToTextCompat() {
        for model in ["kimi-for-coding", "k3", "kimi-for-coding-highspeed"] {
            #expect(SwiftNativeChatOrchestrationClient.shouldUseAnthropicTextStreamingCompatibility(
                model: model))
        }
    }

    @Test func moonshotKimiIdsDoNotRouteToTextCompat() {
        for model in ["kimi-k2-instruct", "kimi-latest", "moonshot-v1-128k"] {
            #expect(!SwiftNativeChatOrchestrationClient.shouldUseAnthropicTextStreamingCompatibility(
                model: model))
        }
    }

    @Test func slackUsesTheSameAnthropicTextToolContractAsChat() {
        for model in ["claude-sonnet-5", "kimi-for-coding"] {
            #expect(SwiftNativeChatOrchestrationClient.shouldUseAnthropicTextStreamingCompatibility(
                model: model))
        }
    }
}

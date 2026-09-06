import Testing
import NativeAgentCore
@testable import ProviderRouting

@Test func astraReasoningControlsRespectAccountAndPublicTransports() {
    for transport in [OpenAIExecutionControls.Transport.chatGPTOAuth, .codexCLI] {
        #expect(OpenAIExecutionControls.reasoningEffort(model: "gpt-6-astra", requested: "ultra", transport: transport) == "ultra")
        #expect(OpenAIExecutionControls.reasoningEffort(model: "gpt-6-astra", requested: "none", transport: transport) == nil)
        #expect(OpenAIExecutionControls.serviceTier(model: "gpt-6-astra", requested: "fast", transport: transport) == "priority")
    }
    #expect(OpenAIExecutionControls.reasoningEffort(model: "gpt-6-astra", requested: "ultra") == nil)
    #expect(OpenAIExecutionControls.reasoningEffort(model: "gpt-6-astra", requested: "max") == "max")
    var body: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("medium") {
        OpenAIExecutionControls.applyResponsesControls(to: &body, model: "gpt-6-astra", transport: .chatGPTOAuth)
    }
    #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
    #expect(body["service_tier"] == nil)
    #expect(OpenAIExecutionControls.wireReasoningEffort(model: "gpt-6-astra", requested: "ultra", transport: .codexCLI) == "ultra")
}

@Test func astraUsesExactPublicAndCodexReasoningContracts() {
    #expect(OpenAIExecutionControls.supportedReasoningEfforts(
        model: "gpt-6-astra",
        transport: .publicAPI
    ) == ["low", "medium", "high", "xhigh", "max"])
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-6-astra",
        requested: "none",
        transport: .publicAPI
    ) == nil)
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-6-astra",
        requested: "ultra",
        transport: .codexCLI
    ) == "ultra")
    #expect(OpenAIExecutionControls.wireReasoningEffort(
        model: "gpt-6-astra",
        requested: "ultra",
        transport: .chatGPTOAuth
    ) == "xhigh")

    var body: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("max") {
        LLMCallContext.$serviceTier.withValue("priority") {
            OpenAIExecutionControls.applyResponsesControls(to: &body, model: "gpt-6-astra")
        }
    }
    #expect((body["reasoning"] as? [String: String])?["effort"] == "max")
    #expect(body["service_tier"] as? String == "priority")
}

@Test func codexBridgeModelCatalogUsesExactCurrentIDs() {
    #expect(OpenAIExecutionControls.codexBridgeModelIDs == [
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra",
    ])
}

@Test func publicGPT56SolRejectsCodexUltraButEmitsMaxAndPriorityTier() {
    var body: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("ultra") {
        LLMCallContext.$serviceTier.withValue("priority") {
            OpenAIExecutionControls.applyResponsesControls(to: &body, model: "gpt-5.6-sol")
        }
    }
    #expect(body["reasoning"] == nil)
    #expect(body["service_tier"] as? String == "priority")

    var maxBody: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("max") {
        OpenAIExecutionControls.applyResponsesControls(to: &maxBody, model: "gpt-5.6-sol")
    }
    let reasoning = maxBody["reasoning"] as? [String: String]
    #expect(reasoning?["effort"] == "max")
}

@Test func gpt56LunaRejectsUltraButAcceptsMax() {
    var ultraBody: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("ultra") {
        OpenAIExecutionControls.applyResponsesControls(to: &ultraBody, model: "gpt-5.6-luna")
    }
    #expect(ultraBody["reasoning"] == nil)

    var maxBody: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("max") {
        OpenAIExecutionControls.applyResponsesControls(to: &maxBody, model: "gpt-5.6-luna")
    }
    let reasoning = maxBody["reasoning"] as? [String: String]
    #expect(reasoning?["effort"] == "max")
}

@Test func fastTierIsNeverSentToNonGPTModels() {
    var body: [String: Any] = [:]
    LLMCallContext.$serviceTier.withValue("priority") {
        OpenAIExecutionControls.applyResponsesControls(to: &body, model: "claude-opus-4-8")
    }
    #expect(body["service_tier"] == nil)
}

@Test func chatCompletionsUsesItsNativeReasoningField() {
    var body: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("max") {
        LLMCallContext.$serviceTier.withValue("priority") {
            OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: "gpt-5.6-terra")
        }
    }
    #expect(body["reasoning_effort"] as? String == "max")
    #expect(body["service_tier"] as? String == "priority")
}

@Test func publicGPT56AliasAcceptsMaxAndNone() {
    for effort in ["max", "none"] {
        var body: [String: Any] = [:]
        LLMCallContext.$reasoningEffort.withValue(effort) {
            OpenAIExecutionControls.applyResponsesControls(to: &body, model: "gpt-5.6")
        }
        let reasoning = body["reasoning"] as? [String: String]
        #expect(reasoning?["effort"] == effort)
    }
}

@Test func codexTransportRetainsAccountCatalogUltra() {
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-5.6-sol",
        requested: "ultra",
        transport: .codexCLI
    ) == "ultra")
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-5.6-luna",
        requested: "ultra",
        transport: .codexCLI
    ) == nil)
}

@Test func chatGPTOAuthRetainsAccountCatalogUltraWithoutChangingPublicAPI() {
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-5.6-sol",
        requested: "ultra",
        transport: .chatGPTOAuth
    ) == "ultra")
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-5.6-luna",
        requested: "ultra",
        transport: .chatGPTOAuth
    ) == nil)
    #expect(OpenAIExecutionControls.reasoningEffort(
        model: "gpt-5.6-sol",
        requested: "ultra",
        transport: .publicAPI
    ) == nil)
}

@Test func chatGPTOAuthMapsCodexClientMaxAndUltraPresetsToDeepestWireEffort() {
    for selected in ["max", "ultra"] {
        #expect(OpenAIExecutionControls.wireReasoningEffort(
            model: "gpt-5.6-sol",
            requested: selected,
            transport: .chatGPTOAuth
        ) == "xhigh")
    }
    #expect(OpenAIExecutionControls.wireReasoningEffort(
        model: "gpt-5.6-sol",
        requested: "ultra",
        transport: .codexCLI
    ) == "ultra")
    #expect(OpenAIExecutionControls.wireReasoningEffort(
        model: "gpt-5.6-sol",
        requested: "max",
        transport: .publicAPI
    ) == "max")
}

@Test func fastTierHonorsTheAccountCatalogForMini() {
    #expect(OpenAIExecutionControls.serviceTier(
        model: "gpt-5.4-mini",
        requested: "priority",
        transport: .chatGPTOAuth
    ) == nil)
    #expect(OpenAIExecutionControls.serviceTier(
        model: "gpt-5.4-mini",
        requested: "priority",
        transport: .codexCLI
    ) == nil)
    #expect(OpenAIExecutionControls.serviceTier(
        model: "gpt-5.4-mini",
        requested: "priority",
        transport: .publicAPI
    ) == "priority")
}

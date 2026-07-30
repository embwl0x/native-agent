import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

@Test func currentFirstPartyCatalogsExposeClaudeSonnet5AndGrok45Capabilities() throws {
    #expect(nativeAgentPrimaryModel == "gpt-5.6-sol")
    #expect(!FirstPartyModelCatalog.publicOpenAIModels.contains { $0.id == "gpt-5.5" })
    #expect(!FirstPartyModelCatalog.chatGPTAccountFallbackModels.contains { $0.id == "gpt-5.5" })
    let sonnet = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: "claude-sonnet-5"))
    #expect(sonnet.contextLength == 1_000_000)
    #expect(sonnet.supportedReasoningEfforts == ["low", "medium", "high", "xhigh", "max"])
    #expect(sonnet.supportsFast == false)

    let grok = try #require(FirstPartyModelCatalog.xAIDescriptor(for: "grok-4.5"))
    #expect(grok.contextLength == 500_000)
    #expect(grok.supportedReasoningEfforts == ["low", "medium", "high"])
    #expect(grok.supportsFast)

    let publicSol = try #require(FirstPartyModelCatalog.publicOpenAIModels.first { $0.id == "gpt-5.6-sol" })
    #expect(publicSol.supportedReasoningEfforts == ["none", "low", "medium", "high", "xhigh", "max"])
    #expect(publicSol.supportedReasoningEfforts.contains("ultra") == false)
    #expect(contextLength(forModel: "gpt-5.6-sol") == 372_000)
    #expect(contextLength(forModel: "claude-sonnet-5") == 1_000_000)
}

@Test func providerScopedDescriptorKeepsPublicAndAccountControlsDistinct() throws {
    let publicSol = try #require(FirstPartyModelCatalog.descriptor(
        for: "gpt-5.6-sol",
        providerID: "openai"
    ))
    let accountSol = try #require(FirstPartyModelCatalog.descriptor(
        for: "gpt-5.6-sol",
        providerID: "openai_oauth_direct"
    ))
    let grok = try #require(FirstPartyModelCatalog.descriptor(
        for: "grok-4.5",
        providerID: "xai_oauth_direct"
    ))

    #expect(publicSol.supportedReasoningEfforts.contains("none"))
    #expect(!publicSol.supportedReasoningEfforts.contains("ultra"))
    #expect(accountSol.supportedReasoningEfforts.contains("ultra"))
    #expect(!accountSol.supportedReasoningEfforts.contains("none"))
    #expect(grok.supportsFast)
}

@Test func anthropicEffortIsEmittedOnlyWhenTheSelectedModelSupportsIt() {
    var opus: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("max") {
        FirstPartyExecutionControls.applyAnthropicControls(to: &opus, model: "claude-opus-4-8")
    }
    #expect((opus["output_config"] as? [String: String])?["effort"] == "max")

    var haiku: [String: Any] = [:]
    LLMCallContext.$reasoningEffort.withValue("none") {
        FirstPartyExecutionControls.applyAnthropicControls(to: &haiku, model: "claude-haiku-4-5")
    }
    #expect(haiku["output_config"] == nil)
}

@Test func anthropicOutputCeilingLeavesRoomForThinkingAndBuilderToolCalls() {
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-opus-5", requestedEffort: "high", explicitOverride: nil
    ) == 65_536)
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-opus-5", requestedEffort: "max", explicitOverride: nil
    ) == 65_536)
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-opus-5", requestedEffort: "medium", explicitOverride: nil
    ) == 32_768)
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-opus-5", requestedEffort: "low", explicitOverride: nil
    ) == 16_384)
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-haiku-4-5", requestedEffort: "none", explicitOverride: nil
    ) == 8_192)
    #expect(FirstPartyExecutionControls.anthropicMaxOutputTokens(
        model: "claude-opus-5", requestedEffort: "high", explicitOverride: 32
    ) == 32)
}

@Test func xAIGrok45EmitsReasoningAndPriorityControls() throws {
    let body = try LLMCallContext.$reasoningEffort.withValue("medium") {
        try LLMCallContext.$serviceTier.withValue("priority") {
            try XAIOAuthDirectAdapter.buildChatCompletionsBody(
                model: "grok-4.5",
                messages: [.user("hello")],
                system: nil,
                tools: nil,
                stream: false
            )
        }
    }
    #expect(body["reasoning_effort"] as? String == "medium")
    #expect(body["service_tier"] as? String == "priority")
}

// R-L1 (tightness round 2): xAI streaming records decoder.usage but never
// asked for it — the body lacked stream_options.include_usage (OpenAI/Moonshot
// set it), so xAI streaming token telemetry was always nil. Streaming bodies
// must now request usage; non-streaming bodies must NOT carry stream_options.
@Test func xAIStreamingBodyRequestsUsage() throws {
    let streaming = try XAIOAuthDirectAdapter.buildChatCompletionsBody(
        model: "grok-4.5", messages: [.user("hi")], system: nil, tools: nil, stream: true
    )
    #expect((streaming["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

    let nonStreaming = try XAIOAuthDirectAdapter.buildChatCompletionsBody(
        model: "grok-4.5", messages: [.user("hi")], system: nil, tools: nil, stream: false
    )
    #expect(nonStreaming["stream_options"] == nil)
}

@Test func modelAwarePreferenceNormalizationKeepsClaudeMaxAndGrokNone() {
    #expect(SwiftNativeProviderRouting.normalizeReasoningEffortStatic(
        "max", fallback: "high", model: "claude-sonnet-5"
    ) == "max")
    #expect(SwiftNativeProviderRouting.normalizeReasoningEffortStatic(
        "high", fallback: "high", model: "grok-4.20-0309-non-reasoning"
    ) == "none")
    #expect(SwiftNativeProviderRouting.normalizeReasoningEffortStatic(
        "none", fallback: "medium", model: "gpt-5.6-sol", providerID: "openai"
    ) == "none")
    #expect(SwiftNativeProviderRouting.normalizeReasoningEffortStatic(
        "ultra", fallback: "medium", model: "gpt-5.6-sol", providerID: "openai_oauth_direct"
    ) == "ultra")
}

@Test func liveXAIOAuthExecutesGrok45_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_XAI_GROK45_TEST"] == "1" else {
        return
    }
    let reply = try await LLMCallContext.$reasoningEffort.withValue("low") {
        try await XAIOAuthDirectAdapter().complete(
            prompt: "Reply exactly OK.",
            system: nil,
            model: "grok-4.5"
        )
    }
    #expect(reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK"))
}

@Test func liveAnthropicOAuthExecutesSonnet5_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_ANTHROPIC_SONNET5_TEST"] == "1" else {
        return
    }
    let reply = try await LLMCallContext.$reasoningEffort.withValue("low") {
        try await AnthropicOAuthDirectAdapter().complete(
            prompt: "Reply exactly OK.",
            system: nil,
            model: "claude-sonnet-5"
        )
    }
    #expect(reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK"))
}

/// Live, opt-in proof for the production OAuth Messages transport's
/// natural cross-turn cache contract. The two calls intentionally share no
/// message prefix and carry different dynamic context; only the stable system
/// segment is identical, matching ordinary independent NativeAgent turns.
@Test func liveAnthropicOAuthStableSystemReusesAcrossIndependentTurns_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_ANTHROPIC_CACHE_TEST"] == "1" else {
        return
    }
    let authPath = try #require(
        ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_ANTHROPIC_AUTH_PATH"]
    )
    let auth = URL(fileURLWithPath: authPath)
    let telemetryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-anthropic-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: telemetryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: telemetryRoot) }

    let adapter = AnthropicOAuthDirectAdapter(
        authPathOverride: auth,
        maxTokens: 32,
        telemetryDataRootOverride: telemetryRoot
    )
    let nonce = UUID().uuidString
    let stable = "Stable NativeAgent tool contract \(nonce). "
        + String(repeating: "Use the verified workspace tools when work is requested. ", count: 320)
    let firstSegments = SystemPromptSegments(
        stable: stable,
        dynamic: "Volatile recall for turn one."
    )
    let secondSegments = SystemPromptSegments(
        stable: stable,
        dynamic: "Different clock, recall, and conversation history for turn two."
    )
    _ = try await AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
        try await LLMCallContext.$systemSegments.withValue(firstSegments) {
            try await LLMCallContext.$reasoningEffort.withValue("low") {
                try await adapter.completeMessages(
                    messages: [.user("Independent first request. Reply exactly FIRST.")],
                    system: firstSegments.combined,
                    model: "claude-opus-5",
                    tools: nil
                )
            }
        }
    }
    _ = try await AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
        try await LLMCallContext.$systemSegments.withValue(secondSegments) {
            try await LLMCallContext.$reasoningEffort.withValue("low") {
                try await adapter.completeMessages(
                    messages: [.user("Independent second request. Reply exactly SECOND.")],
                    system: secondSegments.combined,
                    model: "claude-opus-5",
                    tools: nil
                )
            }
        }
    }

    let events = telemetryRoot
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let lines = try String(contentsOf: events, encoding: .utf8)
        .split(separator: "\n")
    let payloads: [[String: Any]] = lines.compactMap { line in
        guard let data = String(line).data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["kind"] as? String == "llm.call" else { return nil }
        return row["payload"] as? [String: Any]
    }
    #expect(payloads.count == 2)
    #expect((payloads.first?["cacheCreationInputTokens"] as? Int ?? 0) > 0)
    #expect((payloads.last?["cacheReadInputTokens"] as? Int ?? 0) > 0)
}

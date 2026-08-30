import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import SwarmRuns
@testable import ChatOrchestration

private final class SwarmRoutingProbe: LLMClient, @unchecked Sendable {
    struct Call: Sendable {
        let entry: String
        let requestedModel: String?
        let model: String?
        let provider: String?
        let effort: String?
        let tier: String?
        let toolNames: [String]
    }
    private let lock = NSLock()
    private var calls: [Call] = []

    private func record(_ entry: String, model: String?, tools: [LLMToolSchema]? = nil) {
        let call = Call(entry: entry, requestedModel: model, model: LLMCallContext.admittedModel,
                        provider: LLMCallContext.providerId, effort: LLMCallContext.reasoningEffort,
                        tier: LLMCallContext.serviceTier, toolNames: tools?.map(\.name) ?? [])
        lock.withLock { calls.append(call) }
    }
    func snapshot() -> [Call] { lock.withLock { calls } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        record("plain", model: model); return "plain result"
    }
    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        record(prompt.contains("SYNTHESIS:") ? "synthesis" : "worker", model: model)
        return "retained evidence"
    }
    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?) async throws -> String {
        record("tools", model: model, tools: tools); return "tool result"
    }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        record("structured", model: model, tools: tools); return "structured result"
    }
    func streamMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        record("stream", model: model, tools: tools)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("stream one"))
            continuation.yield(.textDelta("stream two"))
            continuation.finish()
        }
    }
}

@Suite("Swarm admitted routing")
struct SwarmAdmittedRoutingTests {
    @Test func parallelWorkerEffortsAndSynthesisUseTheCapturedTuple() async throws {
        let probe = SwarmRoutingProbe()
        let routing = SwarmAdmittedRouting(model: "gpt-5.6-sol", providerID: "codex", effort: "medium", serviceTier: "default")
        let executor = SwiftNativeAgentSwarmExecutor(llm: SwarmAdmittedLLMClient(inner: probe, routing: routing))
        let result = try await LLMCallContext.$admittedModel.withValue("unrelated-parent-model") {
            try await LLMCallContext.$providerId.withValue("unrelated-parent-provider") {
                try await LLMCallContext.$serviceTier.withValue("priority") {
                    try await executor.runTool(input: [
                        "objective": .string("inspect distinct perspectives"),
                        "agents": .array([
                            .object(["role": .string("default")]),
                            .object(["role": .string("quick"), "model": .string("gpt-5.6-terra"), "reasoningEffort": .string("low")]),
                            .object(["role": .string("deep"), "model": .string("claude-opus-4-8"), "reasoningEffort": .string("high")]),
                        ]),
                    ], policy: AgentSwarmPolicy(defaultModel: routing.model, defaultReasoningEffort: routing.effort, storeReceipts: false))
                }
            }
        }
        guard case .object(let receipt) = result else { Issue.record("missing receipt"); return }
        #expect(receipt["status"] == .string("completed"))
        let calls = probe.snapshot()
        #expect(calls.count == 4)
        let defaultWorker = try #require(calls.first { $0.entry == "worker" && $0.requestedModel == routing.model })
        #expect(defaultWorker.effort == "medium")
        #expect(defaultWorker.provider == "codex")
        let quick = try #require(calls.first { $0.requestedModel == "gpt-5.6-terra" })
        #expect(quick.provider == "codex")
        #expect(quick.effort == "low")
        let deep = try #require(calls.first { $0.requestedModel == "claude-opus-4-8" })
        #expect(deep.provider == "anthropic_oauth_direct")
        #expect(deep.effort == "high")
        let synthesis = try #require(calls.first { $0.entry == "synthesis" })
        #expect(synthesis.provider == "codex")
        #expect(synthesis.model == routing.model)
        #expect(synthesis.effort == "medium")
        #expect(calls.allSatisfy { $0.model == $0.requestedModel && $0.tier == "default" })
        #expect(LLMCallContext.reasoningEffort == nil)
    }

    @Test func preservesProviderTransportAndAllForwardedEntryPoints() async throws {
        for provider in ["codex", "openai", "openai_oauth_direct"] {
            let routing = SwarmAdmittedRouting(model: "gpt-5.6-sol", providerID: provider, effort: "medium", serviceTier: "default")
            #expect(routing.provider(for: "gpt-5.6-sol") == provider)
            #expect(routing.provider(for: "gpt-5.6-terra") == provider)
            #expect(routing.provider(for: "claude-opus-4-8") == "anthropic_oauth_direct")
            #expect(routing.provider(for: "unknown-custom-model") == provider)
        }
        let probe = SwarmRoutingProbe()
        let routing = SwarmAdmittedRouting(model: "gpt-5.6-sol", providerID: "openai", effort: "low", serviceTier: "priority")
        let client = SwarmAdmittedLLMClient(inner: probe, routing: routing)
        let schema = LLMToolSchema(name: "read_file", description: "fixture", parametersJSON: Data("{}".utf8))
        _ = try await client.complete(prompt: "p", system: nil, model: routing.model)
        _ = try await client.complete(prompt: "p", system: nil, model: routing.model, tools: [schema])
        let structured = try await client.completeMessages(messages: [.user("p")], system: nil, model: routing.model, surface: "swarms", tools: [schema])
        #expect(structured == "structured result")
        var deltas: [String] = []
        for try await event in client.streamMessages(messages: [.user("p")], system: nil, model: routing.model, surface: "swarms", tools: [schema]) {
            if case .textDelta(let text) = event { deltas.append(text) }
        }
        #expect(deltas == ["stream one", "stream two"])
        let calls = probe.snapshot()
        #expect(calls.map(\.entry) == ["plain", "tools", "structured", "stream"])
        #expect(calls.dropFirst().allSatisfy { $0.toolNames == ["read_file"] })
        #expect(calls.allSatisfy { $0.provider == "openai" && $0.model == routing.model && $0.effort == "low" && $0.tier == "priority" })
    }
}

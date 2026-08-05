import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// gpt-5.5 BLOCKING (2026-08-02) — the SECOND silent Codex fallback.
//
// `OpenRouterUnconfiguredFailsLoudTests` closed the PINNED-provider hole
// (`active["chat"] = "openrouter"` with no adapter). This closes its twin: the
// MODEL-SHAPE hole. `resolveAdapterAndModel` read
//
//     if lower.contains("/"), openRouter != nil { return .openRouter }
//
// so with OpenRouter unconfigured a namespaced `vendor/model` id skipped the
// OpenRouter branch entirely and fell through every first-party prefix rule to
// the terminal `.codex`. A swarms worker asking for
// `anthropic/claude-3.5-sonnet` with no active pin therefore ran on the Codex
// CLI, carrying a model string Codex has never heard of — silently, on the
// user's ChatGPT subscription.
//
// Every test here fails on the pre-fix code by returning "codex-answered".

private struct NoActiveProviderRouter: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider {
        throw ProviderRoutingError.providerNotFound
    }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .object([:]))
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { [:] }
    /// The whole point: NOTHING is pinned, so routing falls to model shape.
    func activeProvidersForSurfaces() async -> [String: String] { [:] }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        ProviderRoutingSnapshot(preferences: [:], activeProviders: [:], pinnedModels: [:])
    }
}

private final class TripwireCodexAdapter: LLMAdapter, @unchecked Sendable {
    let providerId = "codex"
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func note(_ what: String) { lock.lock(); _calls.append(what); lock.unlock() }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        note("complete(\(model))")
        return "codex-answered"
    }

    func complete(
        prompt: String, system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("complete+tools(\(model))")
        return "codex-answered"
    }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("completeMessages(\(model))")
        return "codex-answered"
    }

    func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        note("streamMessages(\(model))")
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("codex-answered"))
            continuation.finish()
        }
    }

    func stream(
        prompt: String, system: String?, model: String
    ) -> AsyncThrowingStream<String, Error> {
        note("stream(\(model))")
        return AsyncThrowingStream { continuation in
            continuation.yield("codex-answered")
            continuation.finish()
        }
    }
}

private final class UnreachableAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    init(_ providerId: String) { self.providerId = providerId }
    func complete(prompt: String, system: String?, model: String) async throws -> String {
        Issue.record("\(providerId) must not serve a namespaced OpenRouter model id")
        return ""
    }
}

private final class RecordingOpenRouter: LLMAdapter, @unchecked Sendable {
    let providerId = "openrouter"
    private let lock = NSLock()
    private var _models: [String] = []
    var models: [String] { lock.lock(); defer { lock.unlock() }; return _models }
    /// Non-async so the lock stays off the async-context unavailability list.
    private func note(_ model: String) { lock.lock(); _models.append(model); lock.unlock() }
    func complete(prompt: String, system: String?, model: String) async throws -> String {
        note(model)
        return "openrouter-answered"
    }
}

@Suite(.serialized)
struct NamespacedModelUnconfiguredOpenRouterTests {
    /// The exact shape from the finding: a swarms worker naming an OpenRouter
    /// model, no active pin anywhere, OpenRouter unconfigured.
    private static let namespacedModel = "anthropic/claude-3.5-sonnet"

    private func makeClient(codex: TripwireCodexAdapter) -> SwiftNativeLLMClient {
        SwiftNativeLLMClient(
            router: NoActiveProviderRouter(),
            codex: codex,
            anthropic: UnreachableAdapter("anthropic"),
            openAI: UnreachableAdapter("openai"),
            openRouter: nil,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
    }

    private func isNotConfiguredOpenRouter(_ error: any Error) -> Bool {
        guard let llm = error as? LLMError,
              case .notConfigured(let provider) = llm else { return false }
        return provider.lowercased().contains("openrouter")
    }

    @Test func complete_namespacedModel_failsLoudInsteadOfRunningOnCodex() async {
        let codex = TripwireCodexAdapter()
        let client = makeClient(codex: codex)
        do {
            _ = try await client.complete(
                prompt: "hi", system: nil, model: Self.namespacedModel,
                surface: "swarms", tools: nil
            )
            Issue.record("expected a loud notConfigured(openrouter), got a reply")
        } catch {
            #expect(isNotConfiguredOpenRouter(error), "wrong error: \(error)")
        }
        #expect(codex.calls.isEmpty, "codex silently served the OpenRouter model: \(codex.calls)")
    }

    @Test func completeMessages_namespacedModel_failsLoudInsteadOfRunningOnCodex() async {
        let codex = TripwireCodexAdapter()
        let client = makeClient(codex: codex)
        do {
            _ = try await client.completeMessages(
                messages: [.user("hi")], system: nil, model: Self.namespacedModel,
                surface: "swarms", tools: nil
            )
            Issue.record("expected a loud notConfigured(openrouter), got a reply")
        } catch {
            #expect(isNotConfiguredOpenRouter(error), "wrong error: \(error)")
        }
        #expect(codex.calls.isEmpty, "codex silently served the OpenRouter model: \(codex.calls)")
    }

    @Test func streamMessages_namespacedModel_failsLoudInsteadOfRunningOnCodex() async {
        let codex = TripwireCodexAdapter()
        let client = makeClient(codex: codex)
        var events: [LLMMessageStreamEvent] = []
        var caught: (any Error)?
        do {
            for try await event in client.streamMessages(
                messages: [.user("hi")], system: nil, model: Self.namespacedModel,
                surface: "swarms", tools: nil
            ) {
                events.append(event)
            }
        } catch {
            caught = error
        }
        #expect(caught.map(isNotConfiguredOpenRouter) == true,
                "wrong error: \(String(describing: caught))")
        #expect(events.isEmpty, "a degraded codex stream leaked text: \(events)")
        #expect(codex.calls.isEmpty, "codex silently served the OpenRouter model: \(codex.calls)")
    }

    @Test func stream_namespacedModel_failsLoudInsteadOfRunningOnCodex() async {
        let codex = TripwireCodexAdapter()
        let client = makeClient(codex: codex)
        var chunks: [String] = []
        var caught: (any Error)?
        do {
            for try await chunk in client.stream(
                prompt: "hi", system: nil, model: Self.namespacedModel, surface: "swarms"
            ) {
                chunks.append(chunk)
            }
        } catch {
            caught = error
        }
        #expect(caught.map(isNotConfiguredOpenRouter) == true,
                "wrong error: \(String(describing: caught))")
        #expect(chunks.isEmpty, "a degraded codex stream leaked text: \(chunks)")
        #expect(codex.calls.isEmpty, "codex silently served the OpenRouter model: \(codex.calls)")
    }

    /// Guard against over-reach #1: with OpenRouter CONFIGURED, the same
    /// namespaced id must still route there, unmodified.
    @Test func configuredOpenRouter_stillServesTheNamespacedModel() async throws {
        let codex = TripwireCodexAdapter()
        let openRouter = RecordingOpenRouter()
        let client = SwiftNativeLLMClient(
            router: NoActiveProviderRouter(),
            codex: codex,
            anthropic: UnreachableAdapter("anthropic"),
            openAI: UnreachableAdapter("openai"),
            openRouter: openRouter,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let reply = try await client.complete(
            prompt: "hi", system: nil, model: Self.namespacedModel,
            surface: "swarms", tools: nil
        )
        #expect(reply == "openrouter-answered")
        #expect(openRouter.models == [Self.namespacedModel])
        #expect(codex.calls.isEmpty)
    }

    /// Guard against over-reach #2: a NON-namespaced id that no first-party
    /// rule claims still falls through to Codex, which is the correct default.
    @Test func plainModelId_stillFallsThroughToCodex() async throws {
        let codex = TripwireCodexAdapter()
        let client = makeClient(codex: codex)
        let reply = try await client.complete(
            prompt: "hi", system: nil, model: "o3-mini", surface: "swarms", tools: nil
        )
        #expect(reply == "codex-answered")
        #expect(codex.calls.count == 1)
    }
}

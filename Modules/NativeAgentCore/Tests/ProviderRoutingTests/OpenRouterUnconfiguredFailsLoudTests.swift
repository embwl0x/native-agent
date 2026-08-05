import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// F-B1 (2026-08-02) — silent-capability-loss regression suite.
//
// `adapterChoice(forProviderId:)` used to read
//     case "openrouter": return openRouter != nil ? .openRouter : .codex
// and each of the FIVE dispatch sites (complete / completeMessages /
// streamMessages / stream, plus the choice resolver itself) quietly re-routed
// an explicit `openrouter` pin to the Codex CLI when OpenRouter was
// unconfigured. That spends a ChatGPT subscription on a different model and
// says nothing. NORTHSTAR clause 2 is FAIL LOUD: every OTHER missing adapter in
// that switch throws `.notConfigured`.
//
// Each test below asserts BOTH halves: the error is raised, AND the Codex
// adapter was never touched. On the pre-fix code every one of them fails by
// returning "codex-answered" instead of throwing.

private struct PinnedRouter: ProviderRoutingProtocol {
    var active: [String: String]
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
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "anthropic/claude-3.5-sonnet", reasoningEffort: "medium")]
    }
    func activeProvidersForSurfaces() async -> [String: String] { active }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        ProviderRoutingSnapshot(
            preferences: try await computeModelPreferences(),
            activeProviders: active,
            pinnedModels: [:]
        )
    }
}

/// Records whether it was ever asked to do anything. If OpenRouter degrades
/// silently, this adapter is what actually runs the user's turn.
private final class TripwireCodex: LLMAdapter, @unchecked Sendable {
    let providerId = "codex"
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    private func note(_ what: String) { lock.lock(); _calls.append(what); lock.unlock() }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        note("complete")
        return "codex-answered"
    }

    func complete(
        prompt: String, system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("complete+tools")
        return "codex-answered"
    }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("completeMessages")
        return "codex-answered"
    }

    func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        note("streamMessages")
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("codex-answered"))
            continuation.finish()
        }
    }

    func stream(
        prompt: String, system: String?, model: String
    ) -> AsyncThrowingStream<String, Error> {
        note("stream")
        return AsyncThrowingStream { continuation in
            continuation.yield("codex-answered")
            continuation.finish()
        }
    }
}

private final class InertAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    init(_ providerId: String) { self.providerId = providerId }
    func complete(prompt: String, system: String?, model: String) async throws -> String {
        Issue.record("\(providerId) adapter must not be reached for an openrouter pin")
        return ""
    }
}

@Suite(.serialized)
struct OpenRouterUnconfiguredFailsLoudTests {

    private func makeClient(codex: TripwireCodex) -> SwiftNativeLLMClient {
        SwiftNativeLLMClient(
            router: PinnedRouter(active: ["chat": "openrouter"]),
            codex: codex,
            anthropic: InertAdapter("anthropic"),
            openAI: InertAdapter("openai"),
            openRouter: nil,  // the whole point: OpenRouter is NOT configured
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
    }

    private func isNotConfiguredOpenRouter(_ error: any Error) -> Bool {
        guard let llm = error as? LLMError,
              case .notConfigured(let provider) = llm else { return false }
        return provider.lowercased().contains("openrouter")
    }

    @Test func complete_throwsNotConfiguredInsteadOfSpendingCodex() async {
        let codex = TripwireCodex()
        let client = makeClient(codex: codex)
        do {
            _ = try await client.complete(
                prompt: "hi", system: nil, model: nil, surface: "chat", tools: nil
            )
            Issue.record("expected a loud notConfigured error, got a reply")
        } catch {
            #expect(isNotConfiguredOpenRouter(error), "wrong error: \(error)")
        }
        #expect(codex.calls.isEmpty, "codex was silently billed: \(codex.calls)")
    }

    @Test func completeMessages_throwsNotConfiguredInsteadOfSpendingCodex() async {
        let codex = TripwireCodex()
        let client = makeClient(codex: codex)
        do {
            _ = try await client.completeMessages(
                messages: [.user("hi")], system: nil, model: nil, surface: "chat", tools: nil
            )
            Issue.record("expected a loud notConfigured error, got a reply")
        } catch {
            #expect(isNotConfiguredOpenRouter(error), "wrong error: \(error)")
        }
        #expect(codex.calls.isEmpty, "codex was silently billed: \(codex.calls)")
    }

    @Test func streamMessages_throwsNotConfiguredInsteadOfSpendingCodex() async {
        let codex = TripwireCodex()
        let client = makeClient(codex: codex)
        var events: [LLMMessageStreamEvent] = []
        var caught: (any Error)?
        do {
            for try await event in client.streamMessages(
                messages: [.user("hi")], system: nil, model: nil, surface: "chat", tools: nil
            ) {
                events.append(event)
            }
        } catch {
            caught = error
        }
        #expect(caught.map(isNotConfiguredOpenRouter) == true, "wrong error: \(String(describing: caught))")
        #expect(events.isEmpty, "a degraded codex stream leaked text: \(events)")
        #expect(codex.calls.isEmpty, "codex was silently billed: \(codex.calls)")
    }

    @Test func stream_throwsNotConfiguredInsteadOfSpendingCodex() async {
        let codex = TripwireCodex()
        let client = makeClient(codex: codex)
        var chunks: [String] = []
        var caught: (any Error)?
        do {
            for try await chunk in client.stream(
                prompt: "hi", system: nil, model: nil, surface: "chat"
            ) {
                chunks.append(chunk)
            }
        } catch {
            caught = error
        }
        #expect(caught.map(isNotConfiguredOpenRouter) == true, "wrong error: \(String(describing: caught))")
        #expect(chunks.isEmpty, "a degraded codex stream leaked text: \(chunks)")
        #expect(codex.calls.isEmpty, "codex was silently billed: \(codex.calls)")
    }

    /// The CONFIGURED case must still route to OpenRouter — the fix must not
    /// have turned a working pin into an error.
    @Test func configuredOpenRouterStillRoutesToOpenRouter() async throws {
        final class OR: LLMAdapter, @unchecked Sendable {
            let providerId = "openrouter"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                "openrouter-answered"
            }
        }
        let codex = TripwireCodex()
        let client = SwiftNativeLLMClient(
            router: PinnedRouter(active: ["chat": "openrouter"]),
            codex: codex,
            anthropic: InertAdapter("anthropic"),
            openAI: InertAdapter("openai"),
            openRouter: OR(),
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let reply = try await client.complete(
            prompt: "hi", system: nil, model: nil, surface: "chat", tools: nil
        )
        #expect(reply == "openrouter-answered")
        #expect(codex.calls.isEmpty)
    }
}

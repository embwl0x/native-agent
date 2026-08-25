import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// NORTHSTAR clause 2 — the OAuth-direct model-substitution hole.
//
// Both first-party OAuth-direct adapters ended their model coercion with a
// terminal catch-all: anything they did not recognize came back as their own
// hardcoded default (`claude-opus-4-8` / the primary GPT id). A surface pinned
// to `anthropic_oauth_direct` with model `llama-3` therefore ran a full,
// BILLED Claude Opus call and nothing anywhere said the model had changed.
// The routing family-mismatch check could not catch it either:
// `inferredProviderId(forModel:)` returns nil for an unknown id, so the guard
// never fired and the raw id reached the pinned adapter.
//
// Three gates now stand where the catch-all was:
//   1. `coerceToClaudeModel` / `coerceToGPTModel` throw `modelUnavailable`.
//   2. Streaming factories coerce INSIDE the stream task and finish throwing.
//   3. `validateCatalogAvailability` rejects an un-inferrable model pinned to a
//      first-party OAuth provider BEFORE dispatch — no HTTP, no token spend.

// MARK: - Anthropic coercion (unit)

@Suite struct AnthropicOAuthDirectModelCoercionTests {
    @Test func passes_claude_ids_through() throws {
        #expect(try AnthropicOAuthDirectAdapter.coerceToClaudeModel("claude-opus-4-8")
                == "claude-opus-4-8")
        #expect(try AnthropicOAuthDirectAdapter.coerceToClaudeModel("claude-sonnet-5")
                == "claude-sonnet-5")
    }

    @Test func strips_anthropic_namespace() throws {
        #expect(try AnthropicOAuthDirectAdapter.coerceToClaudeModel("anthropic/claude-sonnet-5")
                == "claude-sonnet-5")
    }

    @Test func defaults_only_for_absent_request() throws {
        // No model requested is not a substituted pick — the adapter default
        // still applies.
        #expect(try AnthropicOAuthDirectAdapter.coerceToClaudeModel(nil).hasPrefix("claude-"))
        #expect(try AnthropicOAuthDirectAdapter.coerceToClaudeModel("").hasPrefix("claude-"))
    }

    /// The bug: these all used to come back as `claude-opus-4-8`.
    @Test func throws_on_unrecognized_id() throws {
        for unknown in ["llama-3", "deepseek-chat", "o3", "gpt-4o", "anthropic/llama-3"] {
            var thrown: (any Error)?
            do {
                _ = try AnthropicOAuthDirectAdapter.coerceToClaudeModel(unknown)
            } catch {
                thrown = error
            }
            guard case .modelUnavailable(let provider, let model)? = thrown as? LLMError else {
                Issue.record("expected modelUnavailable for \(unknown), got \(String(describing: thrown))")
                continue
            }
            #expect(provider == "anthropic_oauth_direct")
            #expect(model == unknown)
        }
    }

    @Test func substitution_trace_only_on_a_real_rewrite() throws {
        let stripped = try AnthropicOAuthDirectAdapter.coerceToClaudeModel("anthropic/claude-sonnet-5")
        #expect(AnthropicOAuthDirectAdapter.substitutionTrace(
            requested: "anthropic/claude-sonnet-5", coerced: stripped) == "anthropic/claude-sonnet-5")
        let passthrough = try AnthropicOAuthDirectAdapter.coerceToClaudeModel("claude-sonnet-5")
        #expect(AnthropicOAuthDirectAdapter.substitutionTrace(
            requested: "claude-sonnet-5", coerced: passthrough) == nil)
        #expect(AnthropicOAuthDirectAdapter.substitutionTrace(
            requested: nil, coerced: "claude-opus-4-8") == nil)
    }
}

// MARK: - Resolution-level rejection (no HTTP, no token spend)

private struct PinnedProviderRouter: ProviderRoutingProtocol {
    let providerId: String
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
    func activeProvidersForSurfaces() async -> [String: String] { ["chat": providerId] }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        ProviderRoutingSnapshot(
            preferences: [:],
            activeProviders: ["chat": providerId],
            pinnedModels: [:]
        )
    }
}

/// Any call reaching this adapter means the pre-dispatch gate failed — a real
/// adapter here would have opened a socket and burned tokens.
private final class TripwireAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func note(_ what: String) { lock.lock(); _calls.append(what); lock.unlock() }

    init(_ providerId: String) { self.providerId = providerId }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        note("complete(\(model))")
        return "adapter-answered"
    }

    func complete(
        prompt: String, system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("complete+tools(\(model))")
        return "adapter-answered"
    }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        note("completeMessages(\(model))")
        return "adapter-answered"
    }

    func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        note("streamMessages(\(model))")
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("adapter-answered"))
            continuation.finish()
        }
    }

    func stream(
        prompt: String, system: String?, model: String
    ) -> AsyncThrowingStream<String, Error> {
        note("stream(\(model))")
        return AsyncThrowingStream { continuation in
            continuation.yield("adapter-answered")
            continuation.finish()
        }
    }
}

@Suite(.serialized)
struct FirstPartyOAuthPinnedUnknownModelTests {
    private func makeClient(
        pinned: String,
        anthropic: TripwireAdapter,
        openAI: TripwireAdapter,
        codex: TripwireAdapter
    ) -> SwiftNativeLLMClient {
        SwiftNativeLLMClient(
            router: PinnedProviderRouter(providerId: pinned),
            codex: codex,
            anthropic: TripwireAdapter("anthropic"),
            openAI: TripwireAdapter("openai"),
            openAIOAuthDirect: openAI,
            anthropicOAuthDirect: anthropic,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
    }

    private func isModelUnavailable(
        _ error: (any Error)?,
        provider: String,
        model: String
    ) -> Bool {
        guard case .modelUnavailable(let p, let m)? = error as? LLMError else { return false }
        return p == provider && m == model
    }

    @Test func anthropicOAuthPinned_unknownModel_rejectedBeforeDispatch() async {
        let anthropic = TripwireAdapter("anthropic_oauth_direct")
        let openAI = TripwireAdapter("openai_oauth_direct")
        let codex = TripwireAdapter("codex")
        let client = makeClient(
            pinned: "anthropic_oauth_direct",
            anthropic: anthropic, openAI: openAI, codex: codex
        )
        var caught: (any Error)?
        do {
            _ = try await client.complete(
                prompt: "hi", system: nil, model: "llama-3", surface: "chat", tools: nil
            )
        } catch {
            caught = error
        }
        #expect(
            isModelUnavailable(caught, provider: "anthropic_oauth_direct", model: "llama-3"),
            "wrong error: \(String(describing: caught))"
        )
        #expect(anthropic.calls.isEmpty, "adapter was dispatched: \(anthropic.calls)")
        #expect(codex.calls.isEmpty)
        #expect(openAI.calls.isEmpty)
    }

    @Test func openAIOAuthPinned_unknownModel_rejectedBeforeDispatch() async {
        let anthropic = TripwireAdapter("anthropic_oauth_direct")
        let openAI = TripwireAdapter("openai_oauth_direct")
        let codex = TripwireAdapter("codex")
        let client = makeClient(
            pinned: "openai_oauth_direct",
            anthropic: anthropic, openAI: openAI, codex: codex
        )
        var caught: (any Error)?
        do {
            _ = try await client.completeMessages(
                messages: [.user("hi")], system: nil, model: "deepseek-chat",
                surface: "chat", tools: nil
            )
        } catch {
            caught = error
        }
        #expect(
            isModelUnavailable(caught, provider: "openai_oauth_direct", model: "deepseek-chat"),
            "wrong error: \(String(describing: caught))"
        )
        #expect(openAI.calls.isEmpty, "adapter was dispatched: \(openAI.calls)")
        #expect(anthropic.calls.isEmpty)
        #expect(codex.calls.isEmpty)
    }

    @Test func anthropicOAuthPinned_unknownModel_streamFailsWithNoText() async {
        let anthropic = TripwireAdapter("anthropic_oauth_direct")
        let openAI = TripwireAdapter("openai_oauth_direct")
        let codex = TripwireAdapter("codex")
        let client = makeClient(
            pinned: "anthropic_oauth_direct",
            anthropic: anthropic, openAI: openAI, codex: codex
        )
        var events: [LLMMessageStreamEvent] = []
        var caught: (any Error)?
        do {
            for try await event in client.streamMessages(
                messages: [.user("hi")], system: nil, model: "o3", surface: "chat", tools: nil
            ) {
                events.append(event)
            }
        } catch {
            caught = error
        }
        #expect(
            isModelUnavailable(caught, provider: "anthropic_oauth_direct", model: "o3"),
            "wrong error: \(String(describing: caught))"
        )
        #expect(events.isEmpty, "a degraded stream leaked text: \(events)")
        #expect(anthropic.calls.isEmpty, "adapter was dispatched: \(anthropic.calls)")
    }

    /// Over-reach guard: a model the pinned provider CAN serve still routes
    /// there untouched.
    @Test func anthropicOAuthPinned_claudeModel_stillDispatches() async throws {
        let anthropic = TripwireAdapter("anthropic_oauth_direct")
        let openAI = TripwireAdapter("openai_oauth_direct")
        let codex = TripwireAdapter("codex")
        let client = makeClient(
            pinned: "anthropic_oauth_direct",
            anthropic: anthropic, openAI: openAI, codex: codex
        )
        let reply = try await client.complete(
            prompt: "hi", system: nil, model: "claude-sonnet-5", surface: "chat", tools: nil
        )
        #expect(reply == "adapter-answered")
        #expect(anthropic.calls == ["complete+tools(claude-sonnet-5)"])
    }

    /// Over-reach guard: an unknown id with NO first-party OAuth pin is still
    /// the Codex default — this gate must not swallow that path.
    @Test func unpinnedSurface_unknownModel_stillFallsThroughToCodex() async throws {
        let codex = TripwireAdapter("codex")
        let client = SwiftNativeLLMClient(
            router: PinnedProviderRouter(providerId: "codex"),
            codex: codex,
            anthropic: TripwireAdapter("anthropic"),
            openAI: TripwireAdapter("openai"),
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let reply = try await client.complete(
            prompt: "hi", system: nil, model: "llama-3", surface: "chat", tools: nil
        )
        #expect(reply == "adapter-answered")
        #expect(codex.calls.count == 1)
    }
}

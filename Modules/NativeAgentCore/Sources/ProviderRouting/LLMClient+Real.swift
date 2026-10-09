import Foundation
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace

// MARK: - LLMAdapter

/// One backend (Anthropic / OpenAI / Codex CLI). The real client multiplexes
/// over these by model-id prefix.
public protocol LLMAdapter: Sendable {
    static var supportsTools: Bool { get }
    var supportsTools: Bool { get }
    var providerId: String { get }
    func complete(prompt: String, system: String?, model: String) async throws -> String

    /// Tool-aware variant. When `tools` is nil/empty, the adapter MUST emit a
    /// byte-identical wire request to the no-tools overload. Adapters declare
    /// whether native schemas or the existing text tool protocol can reach
    /// the provider; Codex CLI does not carry NativeAgent tools.
    func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured multi-turn variant. `messages` is the conversation; the
    /// system prompt stays in `system:`.
    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// How `streamMessages` delivers a reply for this call's `tools`.
    /// Required, with no default, so a new adapter has to say how it streams.
    func messagesStreamKind(tools: [LLMToolSchema]?) -> LLMMessagesStreamKind

    /// Structured streaming variant, delivered as `messagesStreamKind` says.
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>

    /// Streaming variant. Default implementation falls back to `complete()`
    /// and yields the full reply as a single chunk so any adapter without a
    /// real SSE / process-streaming implementation degrades gracefully
    /// instead of breaking the streaming code path.
    func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error>
}

/// How an adapter's `streamMessages` delivers a reply. Recorded on the
/// `llm.call` row as `streamKind`.
public enum LLMMessagesStreamKind: String, Sendable {
    /// Provider text deltas and tool calls are yielded as they arrive.
    case incremental
    /// One blocking request; `.keepAlive` heartbeats while it runs, then the
    /// whole reply (and any tool calls) is yielded at once.
    case bufferedKeepAlive = "buffered_keepalive"
    /// One blocking text-only request; `.keepAlive` heartbeats while it runs,
    /// the whole reply is one text delta, and no tool call can come back.
    case bufferedText = "buffered_text"

    /// Bound by SwiftNativeLLMClient around the adapter's `streamMessages`
    /// so the adapter's `llm.call` row carries the kind.
    @TaskLocal public static var current: LLMMessagesStreamKind?
}

extension LLMAdapter {
    public static var supportsTools: Bool { false }
    public var supportsTools: Bool { Self.supportsTools }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Cancellation propagation: when the consumer cancels its Task (or
            // breaks out of the for-await loop), the AsyncThrowingStream calls
            // onTermination. We hop that signal onto the worker Task so the
            // underlying complete() call — which may be making a network/CLI
            // request — gets a Task.checkCancellation() pulse. Without this the
            // worker keeps running silently after the consumer is gone.
            let task = Task {
                do {
                    let text = try await self.complete(
                        prompt: prompt, system: system, model: model
                    )
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - LLMError

public enum LLMError: Error, Equatable, LocalizedError {
    case failure(ProviderFailure)
    case notConfigured(provider: String)
    /// A fresh provider-owned catalog positively excludes an explicitly
    /// selected model. The selection is preserved for user repair; execution
    /// must not substitute a different model or provider.
    case modelUnavailable(provider: String, model: String)
    /// The provider POSITIVELY REJECTED the credentials we sent — an HTTP 401,
    /// or a 403 that means "this key/token is not authorized" (as opposed to a
    /// genuinely-missing key, which stays `.notConfigured`). `detail` carries
    /// the provider's own error-body message when we could parse one, so a
    /// stranger with a revoked or wrong key sees the real cause (reconnect /
    /// check billing) instead of the misleading "you never configured it".
    /// A3.1 (2026-07-22): before this case, 401/dead-OAuth mapped to
    /// `.notConfigured` everywhere and the provider's error body was discarded.
    case authRejected(provider: String, detail: String?)
    case transient(message: String)
    case underlying(message: String)
    case invalidResponse(status: Int)
    /// Provider emitted an explicit error mid-stream (e.g. Anthropic
    /// `event: error` SSE frame with overloaded / rate-limit body). Distinct
    /// from `.transient` so callers can tell pre-stream HTTP errors apart
    /// from mid-stream protocol errors.
    case providerError(message: String)
    /// Stream ended without the provider's documented terminal event
    /// (Anthropic `message_stop`, OpenAI `[DONE]` sentinel), OR ended cleanly
    /// (exit-0 / `[DONE]`) but produced ZERO reply content. Indicates a
    /// truncated / empty reply — a silent EOF or an empty string would
    /// otherwise look like a legitimate clean end (A3.3).
    case streamTruncated(message: String)
    /// The provider ended at its output budget. Retain prose, withhold tools,
    /// and end this turn without replaying the same request.
    case outputLengthLimit(partial: String)

    public static let outputLengthLimitNotice = "The answer hit the length limit. Ask to continue from here."

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your model in Settings to continue."
        case .modelUnavailable: return "The selected model is unavailable; choose another model."
        case .outputLengthLimit: return Self.outputLengthLimitNotice
        default: return ProviderFailure.classify(self)?.errorDescription
        }
    }

    public static let retryAfterMaxSeconds = 3600

    public static func rateLimited(message: String, retryAfterSeconds: Int?) -> LLMError {
        .failure(.rateLimited(retryAfter: retryAfterSeconds.flatMap {
            $0 > 0 ? min($0, retryAfterMaxSeconds) : nil
        }))
    }

    public var retryAfterSeconds: Int? {
        guard case .rateLimited(let delay) = ProviderFailure.classify(self) else { return nil }
        return delay
    }

}

// MARK: - SwiftNativeLLMClient

/// Routes completions and streams using one checked `ProviderRoutingSnapshot`
/// for the surface's provider, model preferences and execution controls.
///
/// A selected provider is required. Model families and account catalogs validate
/// compatibility with that explicit route; they do not choose a backend.
/// Missing adapters, unavailable routing and provider/model mismatches fail
/// without substituting a compatible model or another credential route.
///
/// An admitted turn's model takes precedence over the literal `model` argument.
/// With neither, the model comes from the same snapshot's surface preferences,
/// using Chat preferences when the surface has no entry.
public final class SwiftNativeLLMClient: LLMClient, StreamingLLMClient {
    private let router: any ProviderRoutingProtocol
    private let codex: any LLMAdapter
    private let anthropic: any LLMAdapter
    private let openAI: any LLMAdapter
    /// Adapter for the explicit ChatGPT OAuth route. Reads the bound root's
    /// credentials and calls the ChatGPT Codex Responses backend. If absent,
    /// that route fails as not configured; it never borrows the API-key route.
    private let openAIOAuthDirect: (any LLMAdapter)?
    /// Adapter for the explicit Anthropic OAuth route, including streaming.
    /// If absent, that route fails as not configured; it never borrows the
    /// API-key route.
    private let anthropicOAuthDirect: (any LLMAdapter)?
    /// NativeAgent-owned xAI OAuth provider for first-party Grok models. This
    /// is separate from the X/Twitter connector; it calls api.x.ai as a model
    /// provider after an xAI OAuth login.
    private let xaiOAuthDirect: (any LLMAdapter)?
    /// Moonshot API-key adapter for Kimi models. Kept separate from the
    /// generic OpenAI adapter so provider identity, credentials, endpoint,
    /// K3 reasoning preservation, and live model discovery cannot collapse.
    private let moonshot: (any LLMAdapter)?
    /// Kimi Code SUBSCRIPTION adapter. Speaks the Anthropic Messages protocol
    /// (an AnthropicAdapter pointed at api.kimi.com/coding with the kimi-code
    /// key), so it rides the `.anthropic` AdapterChoice with providerId
    /// "kimi-code" and is selected inside `anthropicAdapter(for:)` — no wire
    /// fork. Optional so existing tests/wirings that omit it keep compiling
    /// (a kimi-code request then surfaces .notConfigured(provider:"kimi-code")).
    private let kimiCode: (any LLMAdapter)?
    /// OpenRouter adapter for slash-namespaced model ids (`anthropic/claude-...`,
    /// `openai/...`, `meta-llama/...`, etc). Optional so existing tests and
    /// non-production wirings keep compiling — when nil, an `openrouter` route
    /// fails `notConfigured(provider: "openrouter")`.
    private let openRouter: (any LLMAdapter)?
    private let streamGuardConfig: ProviderStreamGuardConfig
    private let lifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Exact root for provider-owned rebuildable model catalogs. The public
    /// initializer label retains its older Moonshot-specific name for source
    /// compatibility; OpenRouter retirement checks now use the same root so a
    /// secondary body cannot consult the live user's cache.
    private let moonshotCatalogDataRoot: URL

    public init(
        router: any ProviderRoutingProtocol,
        codex: any LLMAdapter,
        anthropic: any LLMAdapter,
        openAI: any LLMAdapter,
        openAIOAuthDirect: (any LLMAdapter)? = nil,
        anthropicOAuthDirect: (any LLMAdapter)? = nil,
        xaiOAuthDirect: (any LLMAdapter)? = nil,
        moonshot: (any LLMAdapter)? = nil,
        kimiCode: (any LLMAdapter)? = nil,
        openRouter: (any LLMAdapter)? = nil,
        streamGuardConfig: ProviderStreamGuardConfig = .fromEnvironment(),
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        moonshotCatalogDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.router = router
        self.codex = codex
        self.anthropic = anthropic
        self.openAI = openAI
        self.openAIOAuthDirect = openAIOAuthDirect
        self.anthropicOAuthDirect = anthropicOAuthDirect
        self.xaiOAuthDirect = xaiOAuthDirect
        self.moonshot = moonshot
        self.kimiCode = kimiCode
        self.openRouter = openRouter
        self.streamGuardConfig = streamGuardConfig
        self.lifecycleObserver = lifecycleObserver
        self.moonshotCatalogDataRoot = moonshotCatalogDataRoot
    }

    /// First-party OAuth-direct providers serve ONE model family each. When a
    /// surface is pinned to one of them and the requested id belongs to no
    /// family we can infer (`llama-3`, `deepseek-chat`, `o3`), the routing
    /// family-mismatch check above cannot fire — `inferredProviderId` returns
    /// nil — so the raw id used to reach the pinned adapter, which quietly
    /// coerced it to its own default and billed the call. Reject it here,
    /// BEFORE dispatch and before any token spend (NORTHSTAR clause 2). The
    /// adapters' coercion now throws too; this is the earlier, cheaper gate.
    private static let firstPartyOAuthDirectProviderIDs: Set<String> = [
        "anthropic_oauth_direct",
        "openai_oauth_direct",
    ]

    private func validateFirstPartyModelFamily(_ resolution: AdapterResolution) throws {
        let pinned = resolution.providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.firstPartyOAuthDirectProviderIDs.contains(pinned) else { return }
        let requested = resolution.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return }
        guard inferredProviderId(forModel: requested) == nil else { return }
        throw LLMError.modelUnavailable(provider: pinned, model: requested)
    }

    private func validateCatalogAvailability(_ resolution: AdapterResolution) throws {
        if let explicit = LLMCallContext.providerId, adapterChoice(forProviderId: explicit) == nil {
            throw LLMError.notConfigured(provider: explicit)
        }
        if resolution.unrouted {
            throw LLMError.notConfigured(
                provider: resolution.providerId.isEmpty ? "router" : resolution.providerId
            )
        }
        if resolution.familyMismatch {
            throw LLMError.modelUnavailable(
                provider: resolution.providerId,
                model: resolution.model
            )
        }
        try validateFirstPartyModelFamily(resolution)
        guard resolution.choice == .openRouter else { return }
        if OpenRouterModelCatalog.cachedAvailability(
            of: resolution.model,
            dataRoot: moonshotCatalogDataRoot
        ) == .unavailable {
            throw LLMError.modelUnavailable(
                provider: "openrouter",
                model: resolution.model
            )
        }
    }

    /// M-F3: Moonshot recognition is CATALOG MEMBERSHIP, not just the
    /// kimi-/moonshot- prefix — the static first-party rows AND the live
    /// authenticated /v1/models disk cache (account-visible ids need not
    /// carry the prefix; review round 2 caught the static-only guard missing
    /// them).
    private func isMoonshotCatalogModel(_ lowercasedID: String) -> Bool {
        if FirstPartyModelCatalog.descriptor(for: lowercasedID, providerID: "moonshot") != nil {
            return true
        }
        return MoonshotModelCatalog.isKnownCatalogModelID(
            lowercasedID,
            dataRoot: moonshotCatalogDataRoot
        )
    }

    private func providerLifecycleStart(
        resolution: AdapterResolution,
        surface: String,
        streaming: Bool,
        reasoningEffort: String?
    ) async -> LLMCallLifecycleEvent {
        let event = LLMCallLifecycleEvent(
            id: UUID().uuidString.lowercased(),
            phase: .started,
            providerId: resolution.providerId,
            model: resolution.model,
            surface: surface,
            sessionId: LLMCallContext.sessionId,
            turnId: TurnTraceContext.turnId,
            reasoningEffort: reasoningEffort,
            streaming: streaming
        )
        await lifecycleObserver?.observeProviderCall(event)
        return event
    }

    private func providerLifecycleFinish(
        _ started: LLMCallLifecycleEvent,
        phase: LLMCallLifecyclePhase
    ) async {
        await lifecycleObserver?.observeProviderCall(started.terminal(phase))
    }

    /// Written under the request's identity: no row when the adapter's came first.
    private func recordFailedCall(_ started: LLMCallLifecycleEvent, error: Error,
                                  startedAt: TimeInterval, recorded: OSAllocatedUnfairLock<Bool>) async {
        await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
        await LLMCallContext.$surface.withValue(started.surface) {
            await LLMCallTraceRecorder(dataRootOverride: LLMCallContext.traceDataRootOverride).record(
                provider: started.providerId, model: started.model, streaming: started.streaming,
                usage: nil, ttftMs: nil,
                durationMs: Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
                status: "failed", errorDetail: ProviderFailure.diagnosticDescription(error))
        }
        }
    }

    /// Adapter choice produced by `resolveAdapterAndModel`. Used by
    /// both `complete()` and `stream()` so the dispatch logic stays in one
    /// place — prior round had a bug where the streaming path skipped the
    /// active-provider tiebreaker and went straight to Codex on ambiguous
    /// ids while `complete()` correctly consulted active.json.
    private enum AdapterChoice {
        case openRouter
        case anthropic
        case openAI
        case xai
        case moonshot
        case codex
    }

    private struct AdapterResolution {
        let choice: AdapterChoice
        let model: String
        let providerId: String
        /// Set when the surface's active provider cannot serve the requested
        /// model's family. Routing no longer substitutes the provider default
        /// (User, 2026-08-21 — fail loud, the user picks models); the
        /// validation gate throws on this before any dispatch or spend.
        var familyMismatch: Bool = false
        /// S12a: no explicit route exists for this call (or it names a
        /// provider no adapter serves); the validation gate throws before any
        /// dispatch rather than guessing one from the model name.
        var unrouted: Bool = false
    }

    /// Single source of truth for routing: the explicit provider pick for the
    /// call. A model name is checked against it, never used to choose it.
    private func resolveAdapterAndModel(
        model: String,
        surface: String,
        routingSnapshot: ProviderRoutingSnapshot
    ) async -> AdapterResolution {
        let active = routingSnapshot.activeProviders
        let turnProvider = LLMCallContext.providerId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // S12a: the route is the explicit pick — the turn's bound provider,
        // else the surface's own, else Chat's for a surface that inherits
        // Chat's model (`resolveRequestedModel` falls back the same way). A
        // model name alone never picks one: the model-prefix fallthrough that
        // used to sit below routed an unpinned `claude-*` / `gpt-*` / `grok-*`
        // / `kimi-*` / `vendor/model` id to whichever provider its name
        // suggested. No route now fails loud before dispatch.
        let requestedProvider = turnProvider?.isEmpty == false
            ? turnProvider
            : ProviderRoutingSurfaceLookup.value(active, surface) ?? active["chat"]
        guard let activeProvider = requestedProvider,
              let activeChoice = adapterChoice(forProviderId: activeProvider) else {
            return AdapterResolution(
                choice: .codex,
                model: model,
                providerId: requestedProvider ?? "",
                unrouted: true
            )
        }
        if let inferred = inferredProviderId(forModel: model),
           !SwiftNativeProviderRouting.providerCanServeModel(activeProvider, inferredProvider: inferred) {
            // A mismatch used to silently swap in the provider default; since
            // 2026-08-21 (User-directed) it is marked here and
            // validateCatalogAvailability throws modelUnavailable BEFORE
            // dispatch. S12a: swarms no longer re-route a mismatched worker
            // model by its own family — a swarm runs on the Work group's model
            // only (SwarmExecutor.requireBoundModel), so there is nothing left
            // to route by name.
            return AdapterResolution(
                choice: activeChoice,
                model: model,
                providerId: activeProvider,
                familyMismatch: true
            )
        }
        return AdapterResolution(choice: activeChoice, model: model, providerId: activeProvider)
    }

    /// The provider `streamMessages` resolves for this call — the same
    /// snapshot, requested-model and adapter resolution, under the caller's
    /// bound `LLMCallContext`. Nil when the call itself would fail there first.
    public func servingProviderID(model: String?, surface: String) async -> String? {
        guard let routingSnapshot = try? await checkedRoutingSnapshot(),
              let resolvedModel = try? resolveRequestedModel(
                model, surface: surface, routingSnapshot: routingSnapshot
              )
        else { return nil }
        let resolution = await resolveAdapterAndModel(
            model: resolvedModel, surface: surface, routingSnapshot: routingSnapshot
        )
        return resolution.unrouted ? nil : resolution.providerId
    }

    private func openAIAdapter(for providerId: String) throws -> any LLMAdapter {
        if providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "openai" {
            return openAI
        }
        guard let openAIOAuthDirect else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return openAIOAuthDirect
    }

    private func anthropicAdapter(for providerId: String) throws -> any LLMAdapter {
        switch providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic":
            return anthropic
        case "kimi-code":
            // Kimi Code rides the Anthropic wire path at a different endpoint.
            guard let kimiCode else {
                throw LLMError.notConfigured(provider: "kimi-code")
            }
            return kimiCode
        default:
            guard let anthropicOAuthDirect else {
                throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
            }
            return anthropicOAuthDirect
        }
    }

    /// The one provider switch all four dispatch paths share, so a guard added
    /// here cannot be missing from a sibling copy (the F1-M1 guard below once
    /// lived only in the streaming path). `label` is the stream-guard label.
    private func adapter(
        for resolution: AdapterResolution,
        tools: [LLMToolSchema]?
    ) throws -> (adapter: any LLMAdapter, label: String) {
        switch resolution.choice {
        case .openRouter:
            guard let openRouter else { throw LLMError.notConfigured(provider: "openrouter") }
            return (openRouter, "openrouter")
        case .anthropic:
            // F1-M1: the native-tools GATE (usesNativeToolLane) and the
            // resolver decide the provider independently; with
            // LLMCallContext.providerId nil the gate can admit the native lane
            // on the model-id backstop while the resolver keeps an anthropic
            // surface pin. Sending provider-native tools[] on a Claude
            // subscription connection is the documented invariant this defends
            // (NativeToolCapability) — kimi-code is the ONLY anthropic-family
            // adapter probed for the native tools contract. Scoped HERE, not
            // pre-dispatch: OpenAI-shaped lanes receive tools[] legitimately
            // (function calling). FAIL LOUD — never silently strip tools.
            if tools != nil,
               !NativeToolCapability.providerSupportsNativeTools(resolution.providerId) {
                throw LLMError.providerError(message:
                    "native tools[] bound to non-native Anthropic-family adapter "
                    + "'\(resolution.providerId)' for model "
                    + "'\(resolution.model)' — "
                    + "gate/resolver disagreement (F1-M1)")
            }
            return (try anthropicAdapter(for: resolution.providerId), resolution.providerId)
        case .openAI:
            return (try openAIAdapter(for: resolution.providerId), resolution.providerId)
        case .xai:
            guard let xaiOAuthDirect else { throw LLMError.notConfigured(provider: "xai_oauth_direct") }
            return (xaiOAuthDirect, "xai")
        case .moonshot:
            guard let moonshot else { throw LLMError.notConfigured(provider: "moonshot") }
            return (moonshot, "moonshot")
        case .codex:
            return (codex, "codex")
        }
    }

    private func adapterChoice(forProviderId rawProviderId: String) -> AdapterChoice? {
        switch SwiftNativeProviderRouting.normalizeProviderId(rawProviderId) {
        case "anthropic": return .anthropic
        // Kimi Code rides the Anthropic wire choice; anthropicAdapter(for:)
        // dispatches on the "kimi-code" providerId to the right adapter.
        case "kimi-code": return .anthropic
        case "openai": return .openAI
        case "xai": return .xai
        case "moonshot": return .moonshot
        // FAIL LOUD (NORTHSTAR clause 2): an explicit `openrouter` pin resolves
        // to the OpenRouter adapter choice ALWAYS. It used to degrade to
        // `.codex` when OpenRouter was unconfigured, which silently spent the
        // ChatGPT subscription on a different model with no error and no log.
        // Every other missing adapter in this switch surfaces `.notConfigured`
        // at its dispatch site; OpenRouter now does the same.
        case "openrouter": return .openRouter
        case "codex": return .codex
        default: return nil
        }
    }

    private func inferredProviderId(forModel model: String) -> String? {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        if lower.contains("/") { return "openrouter" }
        if lower.hasPrefix("claude")
            || lower.hasPrefix("sonnet/")
            || lower.hasPrefix("opus/")
            || lower.hasPrefix("haiku/") {
            return "anthropic"
        }
        if lower.hasPrefix("gpt") { return "openai" }
        if lower.hasPrefix("grok") { return "xai" }
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) { return "kimi-code" }
        if lower.hasPrefix("kimi-") || lower.hasPrefix("moonshot-") { return "moonshot" }
        // Non-prefixed Moonshot catalog IDs participate in the same provider
        // compatibility check: a mismatched explicit route must fail before
        // dispatch. Membership includes static rows and the live disk cache.
        if isMoonshotCatalogModel(lower) {
            return "moonshot"
        }
        return nil
    }

    private func executionControls(
        for surface: String,
        routingSnapshot: ProviderRoutingSnapshot
    ) -> (effort: String?, serviceTier: String?) {
        let pref = ProviderRoutingSurfaceLookup.value(routingSnapshot.preferences, surface)
            ?? routingSnapshot.preferences["chat"]
        return (
            LLMCallContext.reasoningEffort ?? pref?.reasoningEffort,
            LLMCallContext.serviceTier ?? pref?.serviceTier
        )
    }

    private func resolveRequestedModel(
        _ requestedModel: String?,
        surface: String,
        routingSnapshot: ProviderRoutingSnapshot
    ) throws -> String {
        if let admitted = LLMCallContext.admittedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines), !admitted.isEmpty {
            return admitted
        }
        // Trim BEFORE deciding whether a model was requested: a whitespace-only
        // id must fall through to the surface preference, not reach an adapter
        // as an "explicit" pick that silently takes the adapter default
        // (gpt-5.5 sweep review, 2026-08-21).
        if let requested = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requested.isEmpty {
            return requested
        }
        let model = ProviderRoutingSurfaceLookup.value(routingSnapshot.preferences, surface)?.model
            ?? routingSnapshot.preferences["chat"]?.model
            ?? ""
        guard !model.isEmpty else {
            throw LLMError.notConfigured(provider: "router")
        }
        return model
    }

    /// Wall deadline for non-streaming completions. `ProviderStreamGuard` only
    /// wraps the streaming paths; a plain request/response completion that the
    /// server leaves open past URLSession's timeouts otherwise hangs the turn
    /// with no error (observed 2026-09-05: an OAuth-direct request open >11 min).
    private func withCompletionWall<T: Sendable>(
        _ label: String,
        providerId: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // User, 2026-09-06: bound the per-call wall by what the whole turn has
        // left, minus a reconnect reserve. At the shipped defaults the wall
        // (600s) equalled the interactive/Telegram turn window (600s), so the
        // first hung call spent the entire budget and the reconnect ladder
        // exited on the budget instead of retrying.
        // 2026-09-22 WHY: 300s, not the stream's 600s, on the OAuth-direct routes
        // only. Slowest real non-streaming call there in 14 days was 245s; hung
        // ones sat the full 600s then passed on retry.
        let wall = ProviderRecoveryPolicy.callWallSeconds(
            configured: providerId.hasSuffix("_oauth_direct")
                ? min(streamGuardConfig.wallTimeout, 300) : streamGuardConfig.wallTimeout,
            remainingTurnSeconds: LLMCallContext.remainingTurnSeconds
        )
        guard wall > 0 else {
            return try await ProviderStreamContext.$stallOnly.withValue(true) { try await work() }
        }
        // User, 2026-09-06: this used to race the call against a sleep inside a
        // task group. Leaving a group WAITS for its cancelled children, so a
        // provider that ignores cancellation never let the timeout return and
        // the wall could not release the turn — exactly the hang it was added
        // for. Both sides now run unstructured behind a resume-once gate, the
        // shape `IntraTurnContextCompaction.withDeadline` uses (that type lives
        // in ChatOrchestration, which ProviderRouting deliberately cannot see).
        let child = Task { try await work() }
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: UInt64(wall * 1_000_000_000))
        }
        let once = CompletionWallOnce<T>()
        let outcome: Result<T, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
                once.install(continuation)
                Task {
                    let value = await child.result
                    sleeper.cancel()
                    once.resume(value)
                }
                Task {
                    await sleeper.value
                    guard !sleeper.isCancelled else { return }
                    // User, 2026-09-06: CLAIM FIRST, THEN CANCEL. Cancelling the
                    // child first let a cooperative provider throw
                    // CancellationError and win the once-gate, so a wall
                    // timeout surfaced as a user Stop — the turn persisted
                    // "cancelled" for a stop nobody pressed, and the recovery
                    // ladder skipped a retry it was entitled to.
                    once.resume(.failure(ProviderFailure.Diagnostic(
                        cause: .network, detail: "\(label) completion wall timeout after \(Int(wall))s",
                        deadlineExpired: true
                    )))
                    child.cancel()
                }
            }
        } onCancel: {
            // A Stop returns NOW, even if the provider ignores cancellation.
            child.cancel()
            sleeper.cancel()
            once.resume(.failure(CancellationError()))
        }
        return try outcome.get()
    }

    /// Resume-once gate for `withCompletionWall`'s two racers. Resuming before
    /// the continuation is installed is remembered and applied on install, so a
    /// cancellation that lands first still resolves the wait.
    private final class CompletionWallOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, Error>, Never>?
        private var pending: Result<T, Error>?
        private var resolved = false

        func install(_ continuation: CheckedContinuation<Result<T, Error>, Never>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ value: Result<T, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            pending = value
            lock.unlock()
        }
    }

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "chat", tools: nil)
    }

    private func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        do { return try await router.checkedRoutingSnapshot() }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LLMError.failure(.routingUnavailable) }
    }

    public func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: surface, tools: nil)
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "chat", tools: tools)
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        if LLMCallContext.turnTokenBudget != nil {
            return try await completeMessages(messages: [LLMMessage(role: .user, content: [.text(prompt)])],
                system: system, model: model, surface: surface, tools: tools)
        }
        let routingSnapshot = try await checkedRoutingSnapshot()
        let resolvedModel = try resolveRequestedModel(
            model,
            surface: surface,
            routingSnapshot: routingSnapshot
        )
        let resolution = await resolveAdapterAndModel(
            model: resolvedModel,
            surface: surface,
            routingSnapshot: routingSnapshot
        )
        try validateCatalogAvailability(resolution)
        ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools)
        let effectiveModel = resolution.model
        let controls = executionControls(for: surface, routingSnapshot: routingSnapshot)
        let attemptStartedAt = ProcessInfo.processInfo.systemUptime
        let lifecycle = await providerLifecycleStart(
            resolution: resolution,
            surface: surface,
            streaming: false,
            reasoningEffort: controls.effort
        )
        // U1 step 1: bind the calling surface task-locally so the adapters'
        // llm.call telemetry rows can carry it (no signature changes).
        let recorded = OSAllocatedUnfairLock(initialState: false)
        do {
            let result = try await ProviderRecoveryPolicy.retryOverload { try await withCompletionWall("\(resolution.choice)", providerId: resolution.providerId) { [self] in try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) { try await LLMCallContext.$surface.withValue(surface) {
                try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                return try await adapter(for: resolution, tools: tools).adapter.complete(
                    prompt: prompt, system: system, model: effectiveModel, tools: tools
                )
                    }
                }
            } } } }
            await providerLifecycleFinish(lifecycle, phase: .succeeded)
            return result
        } catch is CancellationError {
            await providerLifecycleFinish(lifecycle, phase: .cancelled)
            throw CancellationError()
        } catch {
            await providerLifecycleFinish(lifecycle, phase: .failed)
            await recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
            throw ProviderFailure.normalize(error)
        }
    }

    /// Structured multi-turn variant. Routes to the same adapter the single-
    /// prompt complete() would pick, then calls its `completeMessages`
    /// override (the two OAuth-direct adapters' overrides emit proper
    /// tool_use/tool_result message arrays; the rest flatten via the default).
    /// `messages` here is just the conversation — system prompt stays in
    /// `system:` per both providers' canonical request shape.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        if LLMCallContext.turnTokenBudget != nil {
            var result = ""
            for try await event in streamMessages(messages: messages, system: system, model: model, surface: surface, tools: tools) {
                switch event {
                case .textDelta(let text): result += text
                case .toolCall(let call):
                    let args = String(decoding: call.inputJSON, as: UTF8.self)
                    result += "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
                case .keepAlive, .replyTextSettled, .toolBoundary: break
                }
            }
            return result
        }
        let routingSnapshot = try await checkedRoutingSnapshot()
        let resolvedModel = try resolveRequestedModel(
            model,
            surface: surface,
            routingSnapshot: routingSnapshot
        )
        let resolution = await resolveAdapterAndModel(
            model: resolvedModel,
            surface: surface,
            routingSnapshot: routingSnapshot
        )
        try validateCatalogAvailability(resolution)
        ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools)
        let effectiveModel = resolution.model
        let controls = executionControls(for: surface, routingSnapshot: routingSnapshot)
        let attemptStartedAt = ProcessInfo.processInfo.systemUptime
        let lifecycle = await providerLifecycleStart(
            resolution: resolution,
            surface: surface,
            streaming: false,
            reasoningEffort: controls.effort
        )
        // U1 step 1: bind the calling surface task-locally for telemetry.
        let recorded = OSAllocatedUnfairLock(initialState: false)
        do {
            let result = try await ProviderRecoveryPolicy.retryOverload { try await withCompletionWall("\(resolution.choice)", providerId: resolution.providerId) { [self] in try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) { try await LLMCallContext.$surface.withValue(surface) {
                try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                return try await adapter(for: resolution, tools: tools).adapter.completeMessages(
                    messages: messages, system: system, model: effectiveModel, tools: tools
                )
                    }
                }
            } } } }
            await providerLifecycleFinish(lifecycle, phase: .succeeded)
            return result
        } catch is CancellationError {
            await providerLifecycleFinish(lifecycle, phase: .cancelled)
            throw CancellationError()
        } catch {
            await providerLifecycleFinish(lifecycle, phase: .failed)
            await recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
            throw ProviderFailure.normalize(error)
        }
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        // U1 step 1: bind the calling surface task-locally for telemetry.
        // 2026-07-21 audit fix: the binding now lives INSIDE the worker Task
        // via the async withValue overload — it previously wrapped the SYNC
        // stream construction while the Task read the value lazily, the
        // G4-5 release-crash LIFO shape (see ChatOrchestration+ToolLoop).
        AsyncThrowingStream { continuation in
            let task = Task {
                await LLMCallContext.$surface.withValue(surface) {
                var lifecycle: LLMCallLifecycleEvent?
                var emittedOutput = false
                let attemptStartedAt = ProcessInfo.processInfo.systemUptime
                let recorded = OSAllocatedUnfairLock(initialState: false)
                do {
                    let routingSnapshot = try await self.checkedRoutingSnapshot()
                    let resolvedModel = try self.resolveRequestedModel(
                        model,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )

                    // Same per-call wall bound as `withCompletionWall`.
                    var streamGuardConfig = self.streamGuardConfig
                    streamGuardConfig.wallTimeout = ProviderRecoveryPolicy.callWallSeconds(
                        configured: streamGuardConfig.wallTimeout,
                        remainingTurnSeconds: LLMCallContext.remainingTurnSeconds
                    )

                    func forward(
                        makeStream: @escaping @Sendable () -> AsyncThrowingStream<LLMMessageStreamEvent, Error>,
                        providerLabel: String
                    ) async throws {
                        let guardedStream = ProviderStreamGuard.wrap(
                            makeUpstream: makeStream,
                            config: streamGuardConfig,
                            providerLabel: providerLabel
                        )
                        for try await event in guardedStream {
                            try Task.checkCancellation()
                            switch event {
                            case .keepAlive, .replyTextSettled: break
                            case .textDelta(let text): emittedOutput = emittedOutput || !text.isEmpty
                            case .toolCall, .toolBoundary: emittedOutput = true
                            }
                            if let budget = LLMCallContext.turnTokenBudget {
                                switch event {
                                case .textDelta(let delta):
                                    let kept = budget.take(delta)
                                    if !kept.isEmpty { continuation.yield(.textDelta(kept)) }
                                case .toolCall(let call):
                                    _ = budget.take(call.name + String(decoding: call.inputJSON, as: UTF8.self), visible: false)
                                    if !budget.exhausted { continuation.yield(event) }
                                case .keepAlive, .replyTextSettled, .toolBoundary: continuation.yield(event)
                                }
                                if budget.exhausted { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                            } else { continuation.yield(event) }
                        }
                    }

                    if let budget = LLMCallContext.turnTokenBudget, !budget.beginRequest() { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                    let resolution = await self.resolveAdapterAndModel(
                        model: resolvedModel,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )
                    try self.validateCatalogAvailability(resolution)
                    ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools)
                    // F1-M1 NOTE: the guard for "tools[] must never reach a
                    // Claude OAuth adapter" lives inside `adapter(for:tools:)`'s
                    // `.anthropic` case — NOT here. `tools != nil` is NOT
                    // native-lane-exclusive: the structured tool loop
                    // (ChatOrchestration+ToolLoop) passes provider tool schemas
                    // to EVERY provider for function calling, so a blanket
                    // pre-dispatch check would kill legitimate openai/codex/xai
                    // structured turns (it did — chatClient_streamingFreezes…
                    // caught exactly that).
                    let effectiveModel = resolution.model
                    let controls = self.executionControls(
                        for: surface,
                        routingSnapshot: routingSnapshot
                    )
                    let started = await self.providerLifecycleStart(
                        resolution: resolution,
                        surface: surface,
                        streaming: true,
                        reasoningEffort: controls.effort
                    )
                    lifecycle = started
                    try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
                    try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                    let (adapter, providerLabel) = try self.adapter(for: resolution, tools: tools)
                    try await ProviderStreamContext.$stallOnly.withValue(streamGuardConfig.wallTimeout == 0) {
                    try await LLMMessagesStreamKind.$current.withValue(adapter.messagesStreamKind(tools: tools)) {
                    try await forward(makeStream: { adapter.streamMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    ) }, providerLabel: providerLabel)
                    }
                    }
                    }
                    }
                    }
                    // User, 2026-09-06: cancellation can resume the iteration's
                    // next() with nil instead of throwing, so the in-loop
                    // checkCancellation never runs and a stopped stream was
                    // recorded as `.succeeded`. Ask once more at EOF.
                    try Task.checkCancellation()
                    await self.providerLifecycleFinish(started, phase: .succeeded)
                    continuation.finish()
                } catch is CancellationError {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .cancelled)
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .failed)
                        await self.recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
                    }
                    let failure = ProviderFailure.normalize(error)
                    continuation.finish(throwing: emittedOutput
                        ? ProviderRecoveryPolicy.stopOverload(failure, exhausted: false) : failure)
                }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: StreamingLLMClient

    /// Mirror of `complete(...)`'s dispatch: by-prefix routing to the right
    /// adapter's `stream(...)`. Same router fallback when `model` is nil/empty.
    /// Errors during model-resolution surface as the stream finishing with the
    /// thrown error (no chunks yielded).
    ///
    /// Codex/* models now flow through `CodexAdapter.stream(...)` which spawns
    /// the CLI under a `readabilityHandler` and emits incremental stdout
    /// chunks (was: single-chunk fallback via `LLMAdapter.stream` default).
    /// Anthropic + OpenAI continue to stream via their respective SSE parsers.
    public func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        stream(prompt: prompt, system: system, model: model, surface: "chat")
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) -> AsyncThrowingStream<String, Error> {
        ProviderRecoveryPolicy.retryOverloadStream(hasOutput: { !$0.isEmpty }) { [self] in
            streamAttempt(prompt: prompt, system: system, model: model, surface: surface)
        }
    }

    private func streamAttempt(
        prompt: String, system: String?, model: String?, surface: String
    ) -> AsyncThrowingStream<String, Error> {
        // U1 step 1: bind the calling surface task-locally for telemetry.
        // 2026-07-21 audit fix: bound INSIDE the worker Task via the async
        // withValue overload (was a sync binding around construction — the
        // G4-5 release-crash LIFO shape; see ChatOrchestration+ToolLoop).
        AsyncThrowingStream { continuation in
            // Same per-call wall bound as `withCompletionWall`.
            var streamGuardConfig = self.streamGuardConfig
            streamGuardConfig.wallTimeout = ProviderRecoveryPolicy.callWallSeconds(
                configured: streamGuardConfig.wallTimeout,
                remainingTurnSeconds: LLMCallContext.remainingTurnSeconds
            )
            // Hoist the worker Task into a binding so onTermination can cancel
            // it. Without this, a cancelled consumer (chat-turn aborted, view
            // dismissed, etc.) would leave the inner adapter.stream() iteration
            // — and any network/CLI work behind it — running silently.
            let task = Task {
                await LLMCallContext.$surface.withValue(surface) {
                var lifecycle: LLMCallLifecycleEvent?
                let attemptStartedAt = ProcessInfo.processInfo.systemUptime
                let recorded = OSAllocatedUnfairLock(initialState: false)
                let routingSnapshot: ProviderRoutingSnapshot
                let resolvedModel: String
                do {
                    if let budget = LLMCallContext.turnTokenBudget, !budget.beginRequest() { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                    routingSnapshot = try await self.checkedRoutingSnapshot()
                    resolvedModel = try self.resolveRequestedModel(
                        model,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )
                } catch {
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                    return
                }
                // Use the same resolveAdapter() helper as complete() so the
                // ambiguous-id active.json tiebreaker actually fires here too.
                // Prior wiring went straight to codex on no-prefix ids while
                // complete() correctly honored active.json.
                let resolution = await self.resolveAdapterAndModel(
                    model: resolvedModel,
                    surface: surface,
                    routingSnapshot: routingSnapshot
                )
                do {
                    try self.validateCatalogAvailability(resolution)
                } catch {
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                    return
                }
                let effectiveModel = resolution.model
                let controls = self.executionControls(
                    for: surface,
                    routingSnapshot: routingSnapshot
                )
                let started = await self.providerLifecycleStart(
                    resolution: resolution,
                    surface: surface,
                    streaming: true,
                    reasoningEffort: controls.effort
                )
                lifecycle = started
                await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
                await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                let adapter: any LLMAdapter
                let providerLabel: String
                do {
                    let resolved = try self.adapter(for: resolution, tools: nil)
                    adapter = resolved.adapter
                    providerLabel = resolved.label
                } catch {
                    await self.providerLifecycleFinish(started, phase: .failed)
                    await self.recordFailedCall(started, error: error, startedAt: attemptStartedAt, recorded: recorded)
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                    return
                }
                let guardedStream = ProviderStreamGuard.wrap(
                    makeUpstream: { adapter.stream(prompt: prompt, system: system, model: effectiveModel) },
                    config: streamGuardConfig,
                    providerLabel: providerLabel
                )
                do {
                    for try await chunk in guardedStream {
                        try Task.checkCancellation()
                        if let budget = LLMCallContext.turnTokenBudget {
                            let kept = budget.take(chunk)
                            if !kept.isEmpty { continuation.yield(kept) }
                            if budget.exhausted { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                        } else { continuation.yield(chunk) }
                    }
                    // See the messages wrapper above: a cancellation that ends
                    // the stream with nil must not record `.succeeded`.
                    try Task.checkCancellation()
                    await self.providerLifecycleFinish(started, phase: .succeeded)
                    continuation.finish()
                } catch is CancellationError {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .cancelled)
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .failed)
                        await self.recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
                    }
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
                }
                }
                }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Credentials resolver

/// One credential source per API-key provider: the Keychain reference Settings
/// saves into `<dataRoot>/providers/<providerConfigFile>` (or a legacy api_key). No environment
/// variable and no other provider's file (the Codex CLI's `auth.json`) is
/// consulted — a key that is not there is `nil`, and the caller fails with
/// `notConfigured` naming the provider.
public enum LLMCredentialResolver {
    public static func resolveAPIKey(providerConfigFile: String, dataRoot: URL) -> String? {
        let path = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(providerConfigFile)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return resolveAPIKey(
            providerConfigObject: try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// User, 2026-09-06: presence-only resolution against a provider config
    /// object the CALLER already read — used by the routing snapshot, which
    /// reads each `providers/<id>.json` once under the same per-file lock
    /// `configureProvider` writes under. Reading the file a second time here,
    /// unlocked, is exactly what let one snapshot decide "which provider is
    /// connected" from one set of bytes and "what that provider defaults to"
    /// from another.
    public static func resolveAPIKey(providerConfigObject: [String: Any]?) -> String? {
        guard let providerConfigObject else { return nil }
        if let storedReference = providerConfigObject[ProviderAPIKeyStore.referenceField] {
            // An unavailable referenced credential must never revive a legacy key.
            guard let reference = storedReference as? String else { return nil }
            return try? ProviderAPIKeyStore.read(reference)
        }
        guard let key = providerConfigObject["api_key"] as? String else { return nil }
        // Return the TRIMMED key: stray whitespace in the config file flows
        // into the auth header and produces a persistent 401 (audit 2026-06-09).
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

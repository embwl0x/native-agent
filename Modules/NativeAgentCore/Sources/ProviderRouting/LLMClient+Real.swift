import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - LLMAdapter

/// One backend (Anthropic / OpenAI / Codex CLI). The real client multiplexes
/// over these by model-id prefix.
public protocol LLMAdapter: Sendable {
    var providerId: String { get }
    func complete(prompt: String, system: String?, model: String) async throws -> String

    /// Tool-aware variant. When `tools` is nil/empty, the adapter MUST emit a
    /// byte-identical wire request to the no-tools overload. Default impl
    /// forwards to the no-tools `complete` so adapters that don't ship tools
    /// (the api-key adapters, the OpenRouter adapter, the Codex CLI adapter)
    /// keep working unchanged. Only the OAuth-direct adapters override.
    func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured multi-turn variant. Default impl flattens to a single prompt
    /// string and calls `complete(...tools:)` so non-tool-aware adapters keep
    /// compiling unchanged. The two OAuth-direct adapters override this to
    /// send proper tool_use / tool_result message arrays (their providers'
    /// canonical contract for the tool-loop).
    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured streaming variant. OAuth-direct adapters can surface
    /// provider text deltas and function/tool-call events directly. The
    /// default implementation falls back to completeMessages and yields the
    /// completed text as a single delta.
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

extension LLMAdapter {
    /// Default tools-aware complete forwards to the no-tools complete so any
    /// adapter that doesn't override stays back-compat.
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model)
    }

    /// Default completeMessages flattens the structured conversation into a
    /// single prompt string (role-prefixed text, tool blocks rendered as
    /// inline annotations) and delegates to `complete(...tools:)`. Non-tool-
    /// loop callers see no change. Tool-loop callers using a non-overriding
    /// adapter degrade to text-append behavior — but at least nothing breaks.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        var parts: [String] = []
        var imageCount = 0
        for m in messages {
            let prefix = m.role == .user ? "USER:" : "ASSISTANT:"
            for block in m.content {
                switch block {
                case .text(let t):
                    parts.append("\(prefix) \(t)")
                case .toolUse(_, let name, let inputJSON):
                    let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                    parts.append("\(prefix) [tool_use \(name) \(argsStr)]")
                case .toolResult(_, let content, _):
                    parts.append("\(prefix) [tool_result] \(content)")
                case .image:
                    // TRIPWIRE: the active LLMAdapter has no native vision
                    // wiring (Codex/OpenRouter/api-key fallthrough). Drop the
                    // bytes (NEVER stringify base64) and count for the note.
                    imageCount += 1
                }
            }
        }
        var combined = parts.joined(separator: "\n")
        if imageCount > 0 {
            let note = "[NOTE TO ASSISTANT: the user attached \(imageCount) image(s) but the active provider/model cannot see images. Tell the user honestly that you could not view the attached image(s) — do NOT guess or pretend to describe them.]"
            combined = combined.isEmpty ? note : note + "\n" + combined
            // Emit a single-chokepoint trace row so every non-vision adapter
            // is covered by one site, not N. Non-fatal: stderr on failure.
            await Self.emitVisionUnsupportedTrace(
                provider: self.providerId,
                model: model,
                imageCount: imageCount
            )
        }
        return try await complete(prompt: combined, system: system, model: model, tools: tools)
    }

    /// Tripwire row: an image attachment hit a non-vision adapter and got
    /// dropped at the default-flatten chokepoint. Mirrors `memory.commit`
    /// trace shape (id/kind/title/status/payload/createdAt) and writes via
    /// `appendJSONLCapped` to `<dataRoot>/traces/events.jsonl`.
    private static func emitVisionUnsupportedTrace(
        provider: String,
        model: String,
        imageCount: Int
    ) async {
        // Destination resolution mirrors LLMCallTraceRecorder.tracesPath: a
        // non-nil override (test-only injection via LLMCallContext) wins,
        // otherwise resolve the live default root at append time. This keeps
        // hermetic suites from dribbling test rows into the LIVE
        // traces/events.jsonl while staying byte-identical in production.
        let dataRoot = LLMCallContext.traceDataRootOverride ?? PersistenceCore.defaultDataRoot()
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("vision.attachment_unsupported"),
            "title": .string("vision_attachment_unsupported"),
            "status": .string("ok"),
            "payload": .object([
                "provider": .string(provider),
                "model": .string(model),
                "imageCount": .int(Int64(imageCount)),
            ]),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            try await appendJSONLCapped(
                row, to: tracesPath, using: persistence,
                logLabel: "LLMAdapter.visionUnsupported"
            )
        } catch {
            FileHandle.standardError.write(
                Data("LLMAdapter: vision.attachment_unsupported trace append failed: \(error)\n".utf8)
            )
        }
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let reply = try await completeMessages(
                        messages: messages,
                        system: system,
                        model: model,
                        tools: tools
                    )
                    if !reply.isEmpty {
                        continuation.yield(.textDelta(reply))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - LLMError

public enum LLMError: Error, Equatable, LocalizedError {
    case notConfigured(provider: String)
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

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let p): return "llm: not configured: \(p)"
        case .authRejected(let p, let detail):
            let base = "llm: \(p) rejected the key/token — reconnect or check billing"
            if let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                return base + " (\(d))"
            }
            return base
        case .transient(let m): return "llm: transient: \(m)"
        case .underlying(let m): return "llm: \(m)"
        case .invalidResponse(let s): return "llm: invalid response status \(s)"
        case .providerError(let m): return "llm: provider error: \(m)"
        case .streamTruncated(let m): return "llm: stream truncated: \(m)"
        }
    }

    // MARK: - Retry-After transport (A3.4)
    //
    // Rather than add an associated value to `.transient` (30+ construction
    // sites plus ~20 exhaustive test matches would churn, and the surface
    // retry ladders match error TEXT not the enum shape), a 429 site builds
    // its transient via `rateLimited(message:retryAfterSeconds:)`, which embeds
    // the honored delay as a parseable ` [retry-after=Ns]` sentinel in the
    // message. The message is exactly where the surface ladders already read,
    // so the delay travels the same channel with zero pattern-match churn.

    /// Upper bound on an honored Retry-After (seconds) — a hostile or buggy
    /// header must never be able to encode an unbounded wait.
    public static let retryAfterMaxSeconds = 3600

    /// Build a `.transient` whose message carries the honored Retry-After when
    /// the provider supplied one. Non-positive / nil delays produce a plain
    /// `.transient(message:)` byte-identical to the pre-A3.4 shape.
    public static func rateLimited(message: String, retryAfterSeconds: Int?) -> LLMError {
        guard let s = retryAfterSeconds, s > 0 else { return .transient(message: message) }
        let capped = min(s, retryAfterMaxSeconds)
        return .transient(message: message + " [retry-after=\(capped)s]")
    }

    /// Extract the honored Retry-After (seconds) from any error text carrying
    /// the ` [retry-after=Ns]` sentinel. Surface retry ladders use this to pick
    /// `max(ladderBackoff, retryAfterSeconds)` for the next attempt.
    public static func retryAfterSeconds(fromDescription description: String) -> Int? {
        guard let range = description.range(
            of: "retry-after=[0-9]+s",
            options: .regularExpression
        ) else { return nil }
        let token = description[range]                       // "retry-after=30s"
        let digits = token.dropFirst("retry-after=".count).dropLast()  // "30"
        guard let secs = Int(digits), secs > 0 else { return nil }
        return min(secs, retryAfterMaxSeconds)
    }

    /// Convenience accessor on the error value itself.
    public var retryAfterSeconds: Int? {
        Self.retryAfterSeconds(fromDescription: errorDescription ?? "")
    }
}

// MARK: - SwiftNativeLLMClient

/// Routes `complete()` / `stream()` to the right backend by model-id prefix.
///
/// Dispatch precedence (top-to-bottom; first match wins):
///   - bare `claude-*`                   -> Anthropic OAuth-direct when present, otherwise Anthropic api-key
///   - bare `gpt-*`                      -> OpenAI    OAuth-direct when present, otherwise OpenAI api-key
///   - `anthropic/...` (with slash)      -> OpenRouter
///   - `openai/...`    (with slash)      -> OpenRouter
///   - any other slash-namespaced id     -> OpenRouter (meta-llama/, mistral/, qwen/, ...)
///   - anything else                     -> Codex CLI (which has its own resolver)
///
/// Why slashes mean OpenRouter: `anthropic/claude-...` and `openai/...` are the
/// canonical OpenRouter namespacing for a model served by an upstream provider.
/// First-party Anthropic IDs are bare (`claude-opus-4-8`) and first-party OpenAI
/// IDs are bare (`gpt-5.5`). Treating `anthropic/...` as first-party Anthropic
/// would silently 404 against the Anthropic API.
///
/// If a per-surface `active.json` pins a provider (`{"telegram":"anthropic"}`),
/// that explicit provider selection is authoritative for that surface. When
/// an old/stale model pick belongs to a different provider family, the router
/// swaps to a provider-compatible default instead of silently calling the
/// wrong backend.
///
/// If `model` is nil/empty we resolve via `router.computeModelPreferences()["chat"]`
/// to honor the per-surface picker. The protocol's `complete(model:)` arg here
/// is treated as a literal modelId — surface lookup is the fallback path.
public final class SwiftNativeLLMClient: LLMClient, StreamingLLMClient {
    private let router: any ProviderRoutingProtocol
    private let codex: any LLMAdapter
    private let anthropic: any LLMAdapter
    private let openAI: any LLMAdapter
    /// WAVE 27 (2026-06-01): preferred adapter for `gpt-*` / `openai/*` model
    /// ids when the user's production environment is OAuth-only. The OAuth-direct
    /// adapter consults `data/codex_home/auth.json::tokens.access_token` and
    /// POSTs to `chatgpt.com/backend-api/codex/responses`. When this adapter
    /// is installed, OAuth errors surface directly; NativeAgent must not
    /// silently swap to an API-key adapter. When this is nil, the legacy
    /// api-key-only path is used for OpenAI calls (older tests /
    /// non-production wiring).
    private let openAIOAuthDirect: (any LLMAdapter)?
    /// WAVE 28 (2026-06-01): preferred adapter for `claude*` / `anthropic/*`
    /// model ids when the user's production environment is OAuth-only (no
    /// ANTHROPIC_API_KEY). The OAuth-direct adapter consults
    /// `data/providers/anthropic_oauth_direct.json::setup_token` and POSTs to
    /// `api.anthropic.com/v1/messages` with the OAuth bearer. When this adapter
    /// is installed, OAuth errors surface directly; nil means the legacy
    /// api-key-only path (older tests / non-production wiring). Unlike the
    /// OpenAI OAuth-direct, this adapter has a real SSE streaming implementation
    /// so it's used for stream() too, not just complete().
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
    /// non-production wirings keep compiling — when nil, slash-prefixed ids
    /// fall through to codex.
    private let openRouter: (any LLMAdapter)?
    private let streamGuardConfig: ProviderStreamGuardConfig
    private let lifecycleObserver: (any LLMCallLifecycleObserving)?
    /// M-F3 (review round 2): where the Moonshot live-catalog disk cache lives.
    /// Routing consults it so account-visible ids WITHOUT the kimi-/moonshot-
    /// prefix still route to moonshot. Injectable for tests; defaults to the
    /// live data root.
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

    /// Adapter choice produced by `resolveAdapter(model:surface:)`. Used by
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
    }

    /// Single source of truth for routing. Explicit active provider wins for
    /// a surface; model prefix is used only when no active provider is set.
    private func resolveAdapter(
        model: String,
        surface: String,
        routingSnapshot: ProviderRoutingSnapshot
    ) async -> AdapterChoice {
        (await resolveAdapterAndModel(
            model: model,
            surface: surface,
            routingSnapshot: routingSnapshot
        )).choice
    }

    private func resolveAdapterAndModel(
        model: String,
        surface: String,
        routingSnapshot: ProviderRoutingSnapshot
    ) async -> AdapterResolution {
        let lower = model.lowercased()
        let active = routingSnapshot.activeProviders
        let turnProvider = LLMCallContext.providerId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedProvider = turnProvider?.isEmpty == false
            ? turnProvider
            : ProviderRoutingSurfaceLookup.value(active, surface)
        if let activeProvider = requestedProvider,
           let activeChoice = adapterChoice(forProviderId: activeProvider) {
            if let inferred = inferredProviderId(forModel: model),
               !providerCanServeModel(activeProvider, inferredProvider: inferred) {
                // Swarms deliberately support explicit per-worker model
                // choices. The checked surface tuple already reconciles the
                // omitted/default model with its active provider, so a family
                // mismatch here means the caller intentionally selected a
                // different worker model. Route that model by its own family
                // instead of silently replacing it with the surface default.
                if surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "swarms" {
                    let fallbackModel = await defaultModel(forProviderId: activeProvider) ?? model
                    return AdapterResolution(
                        choice: activeChoice,
                        model: fallbackModel,
                        providerId: activeProvider
                    )
                }
            } else {
                return AdapterResolution(choice: activeChoice, model: model, providerId: activeProvider)
            }
        }
        if lower.contains("/"), openRouter != nil {
            return AdapterResolution(choice: .openRouter, model: model, providerId: "openrouter")
        }
        if lower.hasPrefix("claude") {
            return AdapterResolution(
                choice: .anthropic,
                model: model,
                providerId: anthropicOAuthDirect == nil ? "anthropic" : "anthropic_oauth_direct"
            )
        }
        if lower.hasPrefix("gpt") {
            return AdapterResolution(
                choice: .openAI,
                model: model,
                providerId: openAIOAuthDirect == nil ? "openai" : "openai_oauth_direct"
            )
        }
        if lower.hasPrefix("grok") {
            return AdapterResolution(choice: .xai, model: model, providerId: "xai_oauth_direct")
        }
        // Kimi Code subscription ids ride the Anthropic wire path (distinct
        // endpoint + key), selected via anthropicAdapter(for:"kimi-code").
        // Checked BEFORE the moonshot `kimi-` prefix branch below.
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) {
            return AdapterResolution(choice: .anthropic, model: model, providerId: "kimi-code")
        }
        if lower.hasPrefix("kimi-") || lower.hasPrefix("moonshot-") {
            return AdapterResolution(choice: .moonshot, model: model, providerId: "moonshot")
        }
        // M-F3: a PINNED Moonshot catalog id that doesn't carry the kimi-/
        // moonshot- prefix (all current static ids do, but the live /v1/models
        // catalog can carry account-visible rows without it) must still route
        // to moonshot — not silently fall through to codex, which would run
        // the wrong backend for a first-party Kimi model. Route by catalog
        // membership: static first-party rows + live disk cache.
        if isMoonshotCatalogModel(lower) {
            return AdapterResolution(choice: .moonshot, model: model, providerId: "moonshot")
        }
        // A namespaced `vendor/model` id is the OpenRouter form, and by here no
        // first-party rule has claimed it. Resolve it to `.openRouter` EVEN IF
        // OpenRouter is unconfigured, so the adapter guard throws
        // `notConfigured(provider: "openrouter")` — the same fail-loud shape the
        // pinned-provider path already produces. Previously this fell through to
        // Codex, so a swarms worker asking for `anthropic/claude-3.5-sonnet`
        // with OpenRouter unconfigured silently ran on the Codex CLI with a
        // model string Codex has never heard of (gpt-5.5 BLOCKING, 2026-08-02).
        if lower.contains("/") {
            return AdapterResolution(choice: .openRouter, model: model, providerId: "openrouter")
        }
        return AdapterResolution(choice: .codex, model: model, providerId: "codex")
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

    private func adapterChoice(forProviderId rawProviderId: String) -> AdapterChoice? {
        switch normalizeProviderId(rawProviderId) {
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
        // M-F3 (symmetry): a non-prefixed pinned Moonshot catalog id belongs
        // to moonshot for the active-provider compatibility check too, so an
        // incompatible active provider swaps to a moonshot-served default
        // instead of shipping a Kimi model to the wrong backend. Same
        // membership oracle as routing: static rows + live disk cache.
        if isMoonshotCatalogModel(lower) {
            return "moonshot"
        }
        return nil
    }

    private func providerCanServeModel(_ activeProvider: String, inferredProvider: String) -> Bool {
        let active = normalizeProviderId(activeProvider)
        let inferred = normalizeProviderId(inferredProvider)
        return active == inferred || (active == "codex" && inferred == "openai")
    }

    private func normalizeProviderId(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp":
            return "anthropic"
        case "openai", "openai_oauth_direct":
            return "openai"
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai"
        case "moonshot", "kimi":
            return "moonshot"
        case "openrouter":
            return "openrouter"
        case "codex":
            return "codex"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private func defaultModel(forProviderId providerId: String) async -> String? {
        if let provider = try? await router.getProvider(id: providerId),
           let model = Self.defaultModel(from: provider) {
            return model
        }
        switch normalizeProviderId(providerId) {
        case "anthropic": return "claude-opus-4-8"
        case "openai", "codex": return nativeAgentPrimaryModel
        case "xai": return XAIOAuthDirectAdapter.defaultModel
        case "moonshot": return MoonshotAdapter.defaultModel
        case "kimi-code": return "kimi-for-coding"
        case "openrouter": return "anthropic/claude-3.5-sonnet"
        default: return nil
        }
    }

    private static func defaultModel(from provider: Provider) -> String? {
        if case .object(let extras)? = provider.extras {
            for key in ["default_model", "defaultModel"] {
                if case .string(let value)? = extras[key],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        if case .array(let models)? = provider.modelCatalog {
            for item in models {
                guard case .object(let obj) = item else { continue }
                if case .string(let value)? = obj["id"],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
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
        if let requestedModel, !requestedModel.isEmpty {
            return requestedModel
        }
        let model = ProviderRoutingSurfaceLookup.value(routingSnapshot.preferences, surface)?.model
            ?? routingSnapshot.preferences["chat"]?.model
            ?? ""
        guard !model.isEmpty else {
            throw LLMError.notConfigured(provider: "router")
        }
        return model
    }

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "chat", tools: nil)
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
        let routingSnapshot = try await router.checkedRoutingSnapshot()
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
        let effectiveModel = resolution.model
        let controls = executionControls(for: surface, routingSnapshot: routingSnapshot)
        let lifecycle = await providerLifecycleStart(
            resolution: resolution,
            surface: surface,
            streaming: false,
            reasoningEffort: controls.effort
        )
        // U1 step 1: bind the calling surface task-locally so the adapters'
        // llm.call telemetry rows can carry it (no signature changes).
        do {
            let result = try await LLMCallContext.$surface.withValue(surface) {
                try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                switch resolution.choice {
                case .openRouter:
                    guard let or = openRouter else {
                        throw LLMError.notConfigured(provider: "openrouter")
                    }
                    return try await or.complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                case .anthropic:
                    return try await anthropicAdapter(for: resolution.providerId).complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                case .openAI:
                    return try await openAIAdapter(for: resolution.providerId).complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                case .xai:
                    guard let xai = xaiOAuthDirect else {
                        throw LLMError.notConfigured(provider: "xai_oauth_direct")
                    }
                    return try await xai.complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                case .moonshot:
                    guard let moonshot else { throw LLMError.notConfigured(provider: "moonshot") }
                    return try await moonshot.complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                case .codex:
                    return try await codex.complete(
                        prompt: prompt, system: system, model: effectiveModel, tools: tools
                    )
                }
                    }
                }
            }
            await providerLifecycleFinish(lifecycle, phase: .succeeded)
            return result
        } catch is CancellationError {
            await providerLifecycleFinish(lifecycle, phase: .cancelled)
            throw CancellationError()
        } catch {
            await providerLifecycleFinish(lifecycle, phase: .failed)
            throw error
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
        let routingSnapshot = try await router.checkedRoutingSnapshot()
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
        let effectiveModel = resolution.model
        let controls = executionControls(for: surface, routingSnapshot: routingSnapshot)
        let lifecycle = await providerLifecycleStart(
            resolution: resolution,
            surface: surface,
            streaming: false,
            reasoningEffort: controls.effort
        )
        // U1 step 1: bind the calling surface task-locally for telemetry.
        do {
            let result = try await LLMCallContext.$surface.withValue(surface) {
                try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                switch resolution.choice {
                case .openRouter:
                    guard let or = openRouter else {
                        throw LLMError.notConfigured(provider: "openrouter")
                    }
                    return try await or.completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                case .anthropic:
                    return try await anthropicAdapter(for: resolution.providerId).completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                case .openAI:
                    return try await openAIAdapter(for: resolution.providerId).completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                case .xai:
                    guard let xai = xaiOAuthDirect else {
                        throw LLMError.notConfigured(provider: "xai_oauth_direct")
                    }
                    return try await xai.completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                case .moonshot:
                    guard let moonshot else { throw LLMError.notConfigured(provider: "moonshot") }
                    return try await moonshot.completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                case .codex:
                    return try await codex.completeMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    )
                }
                    }
                }
            }
            await providerLifecycleFinish(lifecycle, phase: .succeeded)
            return result
        } catch is CancellationError {
            await providerLifecycleFinish(lifecycle, phase: .cancelled)
            throw CancellationError()
        } catch {
            await providerLifecycleFinish(lifecycle, phase: .failed)
            throw error
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
                do {
                    let routingSnapshot = try await router.checkedRoutingSnapshot()
                    let resolvedModel = try self.resolveRequestedModel(
                        model,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )

                    let streamGuardConfig = self.streamGuardConfig

                    func forward(
                        _ stream: AsyncThrowingStream<LLMMessageStreamEvent, Error>,
                        providerLabel: String
                    ) async throws {
                        let guardedStream = ProviderStreamGuard.wrap(
                            stream,
                            config: streamGuardConfig,
                            providerLabel: providerLabel
                        )
                        for try await event in guardedStream {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    }

                    let resolution = await self.resolveAdapterAndModel(
                        model: resolvedModel,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )
                    // F1-M1 NOTE: the guard for "tools[] must never reach a
                    // Claude OAuth adapter" lives inside the `.anthropic`
                    // dispatch case below — NOT here. `tools != nil` is NOT
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
                    try await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                    try await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                    switch resolution.choice {
                    case .openRouter:
                        guard let or = openRouter else {
                            throw LLMError.notConfigured(provider: "openrouter")
                        }
                        try await forward(or.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: "openrouter")
                    case .anthropic:
                        // F1-M1: the native-tools GATE (usesNativeToolLane) and
                        // this resolver decide the provider independently; with
                        // LLMCallContext.providerId nil the gate can admit the
                        // native lane on the model-id backstop while the
                        // resolver keeps an anthropic surface pin. Sending
                        // provider-native tools[] on a Claude subscription
                        // connection is the documented invariant this defends
                        // (NativeToolCapability) — kimi-code is the ONLY
                        // anthropic-family adapter probed for the native tools
                        // contract. Scoped HERE, not pre-dispatch: OpenAI-shaped
                        // lanes receive tools[] legitimately (function calling).
                        // FAIL LOUD — never silently strip tools (house rule:
                        // no silent fallbacks).
                        if tools != nil,
                           !NativeToolCapability.providerSupportsNativeTools(resolution.providerId) {
                            throw LLMError.providerError(message:
                                "native tools[] bound to non-native Anthropic-family adapter "
                                + "'\(resolution.providerId)' for model "
                                + "'\(resolution.model)' — "
                                + "gate/resolver disagreement (F1-M1)")
                        }
                        let adapter = try self.anthropicAdapter(for: resolution.providerId)
                        try await forward(adapter.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: resolution.providerId)
                    case .openAI:
                        let adapter = try self.openAIAdapter(for: resolution.providerId)
                        try await forward(adapter.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: resolution.providerId)
                    case .xai:
                        guard let xai = self.xaiOAuthDirect else {
                            throw LLMError.notConfigured(provider: "xai_oauth_direct")
                        }
                        try await forward(xai.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: "xai")
                    case .moonshot:
                        guard let moonshot = self.moonshot else {
                            throw LLMError.notConfigured(provider: "moonshot")
                        }
                        try await forward(moonshot.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: "moonshot")
                    case .codex:
                        try await forward(codex.streamMessages(
                            messages: messages, system: system, model: effectiveModel, tools: tools
                        ), providerLabel: "codex")
                    }
                    }
                    }
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
                    }
                    continuation.finish(throwing: error)
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
        // U1 step 1: bind the calling surface task-locally for telemetry.
        // 2026-07-21 audit fix: bound INSIDE the worker Task via the async
        // withValue overload (was a sync binding around construction — the
        // G4-5 release-crash LIFO shape; see ChatOrchestration+ToolLoop).
        AsyncThrowingStream { continuation in
            let codex = self.codex
            let router = self.router
            let streamGuardConfig = self.streamGuardConfig
            // Hoist the worker Task into a binding so onTermination can cancel
            // it. Without this, a cancelled consumer (chat-turn aborted, view
            // dismissed, etc.) would leave the inner adapter.stream() iteration
            // — and any network/CLI work behind it — running silently.
            let task = Task {
                await LLMCallContext.$surface.withValue(surface) {
                var lifecycle: LLMCallLifecycleEvent?
                let routingSnapshot: ProviderRoutingSnapshot
                let resolvedModel: String
                do {
                    routingSnapshot = try await router.checkedRoutingSnapshot()
                    resolvedModel = try self.resolveRequestedModel(
                        model,
                        surface: surface,
                        routingSnapshot: routingSnapshot
                    )
                } catch {
                    continuation.finish(throwing: error)
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
                await LLMCallContext.$reasoningEffort.withValue(controls.effort) {
                await LLMCallContext.$serviceTier.withValue(controls.serviceTier) {
                let stream: AsyncThrowingStream<String, Error>
                let providerLabel: String
                switch resolution.choice {
                case .openRouter:
                    guard let or = self.openRouter else {
                        await self.providerLifecycleFinish(started, phase: .failed)
                        continuation.finish(throwing: LLMError.notConfigured(provider: "openrouter"))
                        return
                    }
                    stream = or.stream(prompt: prompt, system: system, model: effectiveModel)
                    providerLabel = "openrouter"
                case .anthropic:
                    do {
                        let adapter = try self.anthropicAdapter(for: resolution.providerId)
                        stream = adapter.stream(prompt: prompt, system: system, model: effectiveModel)
                        providerLabel = resolution.providerId
                    } catch {
                        await self.providerLifecycleFinish(started, phase: .failed)
                        continuation.finish(throwing: error)
                        return
                    }
                case .openAI:
                    do {
                        let adapter = try self.openAIAdapter(for: resolution.providerId)
                        stream = adapter.stream(prompt: prompt, system: system, model: effectiveModel)
                        providerLabel = resolution.providerId
                    } catch {
                        await self.providerLifecycleFinish(started, phase: .failed)
                        continuation.finish(throwing: error)
                        return
                    }
                case .xai:
                    guard let xai = self.xaiOAuthDirect else {
                        await self.providerLifecycleFinish(started, phase: .failed)
                        continuation.finish(throwing: LLMError.notConfigured(provider: "xai_oauth_direct"))
                        return
                    }
                    stream = xai.stream(prompt: prompt, system: system, model: effectiveModel)
                    providerLabel = "xai"
                case .moonshot:
                    guard let moonshot = self.moonshot else {
                        await self.providerLifecycleFinish(started, phase: .failed)
                        continuation.finish(throwing: LLMError.notConfigured(provider: "moonshot"))
                        return
                    }
                    stream = moonshot.stream(prompt: prompt, system: system, model: effectiveModel)
                    providerLabel = "moonshot"
                case .codex:
                    stream = codex.stream(prompt: prompt, system: system, model: effectiveModel)
                    providerLabel = "codex"
                }
                let guardedStream = ProviderStreamGuard.wrap(
                    stream,
                    config: streamGuardConfig,
                    providerLabel: providerLabel
                )
                do {
                    for try await chunk in guardedStream {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
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
                    }
                    continuation.finish(throwing: error)
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

/// Three-source credential resolver mirroring Python's daemon precedence:
///   1. ProcessInfo env var (e.g. OPENAI_API_KEY)
///   2. <providers>/<providerConfigFile> with top-level `api_key`
///   3. <codex_home>/auth.json with top-level `OPENAI_API_KEY`
///      (ChatGPT OAuth path — ONLY consulted when the caller is asking for
///      OPENAI_API_KEY; anthropic / other providers must not pick up an OAuth
///      OpenAI key from the codex home, since the key is endpoint-specific.)
/// Each step is best-effort: malformed/missing files fall through to the next.
public enum LLMCredentialResolver {
    /// CWD-relative resolution (legacy default). Resolves the two file sources
    /// under `<cwd>/data/providers` and `<cwd>/data/codex_home`. This is correct
    /// in a dev checkout (the daemon is launched with the repo root as CWD) but
    /// WRONG for an installed `.app` bundle, whose CWD is `/` — there the files
    /// live under the daemon's resolved data root (stamped REPO_PATH /
    /// NATIVE_AGENT_DATA_ROOT / AppSupport), not under the process CWD. Callers
    /// running in an installed build MUST use the `dataRoot:` overload below so
    /// they resolve the SAME `<dataRoot>/providers` + `<dataRoot>/codex_home`
    /// directories the daemon's `_VisionClient` is constructed with
    /// (the retired daemon `provider_config_dir=self.root / "providers"`,
    /// `codex_home=self.app_codex_home()` == `self.root / "codex_home"`).
    public static func resolveAPIKey(envVar: String, providerConfigFile: String) -> String? {
        // Legacy CWD-relative base: <cwd>/data. defaultDataRoot()'s dev branch
        // returns <repo>/data, so the dataRoot overload omits the extra "data"
        // segment — only this CWD path appends it.
        return resolveAPIKey(
            envVar: envVar,
            providerConfigFile: providerConfigFile,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
    }

    static func resolveAPIKey(
        envVar: String,
        providerConfigFile: String,
        currentDirectory: URL
    ) -> String? {
        let base = currentDirectory
            .appendingPathComponent("data", isDirectory: true)
        return resolveAPIKey(
            envVar: envVar,
            providerConfigFile: providerConfigFile,
            providersDir: base.appendingPathComponent("providers", isDirectory: true),
            codexHomeDir: base.appendingPathComponent("codex_home", isDirectory: true)
        )
    }

    /// Data-root-relative resolution for installed builds. `dataRoot` is the
    /// daemon's resolved data root (e.g. from `PersistenceCore.defaultDataRoot()`),
    /// which ALREADY includes the `data` segment in the dev branch and points at
    /// the stamped/AppSupport root in an installed bundle. The file sources are
    /// `<dataRoot>/providers/<providerConfigFile>` and
    /// `<dataRoot>/codex_home/auth.json` — NO extra `data` segment is appended,
    /// matching the daemon's `self.root / "providers"` / `self.root / "codex_home"`.
    public static func resolveAPIKey(
        envVar: String,
        providerConfigFile: String,
        dataRoot: URL,
        includeEnvironment: Bool = true
    ) -> String? {
        return resolveAPIKey(
            envVar: envVar,
            providerConfigFile: providerConfigFile,
            providersDir: dataRoot.appendingPathComponent("providers", isDirectory: true),
            codexHomeDir: dataRoot.appendingPathComponent("codex_home", isDirectory: true),
            includeEnvironment: includeEnvironment
        )
    }

    /// Core resolver: env var → `<providersDir>/<providerConfigFile>` `api_key`
    /// → (OpenAI only) `<codexHomeDir>/auth.json` `OPENAI_API_KEY`. Both public
    /// entry points funnel here so the precedence/parsing semantics stay in one
    /// place and remain tested identically regardless of how the directories
    /// were resolved.
    private static func resolveAPIKey(
        envVar: String,
        providerConfigFile: String,
        providersDir: URL,
        codexHomeDir: URL,
        includeEnvironment: Bool = true
    ) -> String? {
        if includeEnvironment, let v = ProcessInfo.processInfo.environment[envVar] {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Return the TRIMMED key: a trailing newline from `cat
                // keyfile`-style exports flows into the auth header and
                // produces a persistent 401 misreported as not-configured
                // (audit 2026-06-09).
                return trimmed
            }
        }

        let providerPath = providersDir.appendingPathComponent(providerConfigFile)
        if let data = try? Data(contentsOf: providerPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = obj["api_key"] as? String {
            // Return the TRIMMED key, mirroring the env-var branch above —
            // stray whitespace in the config file flows into the auth header
            // and produces a persistent 401 (audit 2026-06-09).
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // codex_home/auth.json holds an `OPENAI_API_KEY` field (Python's
        // ChatGPT-OAuth flow stashes it there). Only the OpenAI resolver
        // should look here — using it for an Anthropic call would point a
        // Bearer at the wrong endpoint and 401 silently.
        if envVar == "OPENAI_API_KEY" {
            let codexAuthPath = codexHomeDir.appendingPathComponent("auth.json")
            if let data = try? Data(contentsOf: codexAuthPath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = obj["OPENAI_API_KEY"] as? String {
                // Trimmed for the same reason as the branches above.
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }
}

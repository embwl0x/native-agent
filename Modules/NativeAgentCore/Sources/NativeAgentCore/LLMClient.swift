import Foundation

// MARK: - LLMCallContext (request-scoped, additive)
//
// U1 step-1/4 (2026-06-10): task-local request context threaded DOWN to the
// provider adapters without changing any public signatures. Two consumers:
//   - `surface`  — bound by SwiftNativeLLMClient around every adapter call so
//     the per-call `llm.call` telemetry row can carry the calling surface
//     (chat / telegram / executions / dream...). Adapters read it at
//     record time; unbound → "unknown".
//   - `sessionId` — bound by the ChatOrchestration tool loop around its
//     llm.completeMessages / llm.streamMessages calls so the OpenAI
//     Responses adapter can derive a STABLE per-session `prompt_cache_key`
//     (server-side prompt-cache routing). Unbound → no prompt_cache_key
//     field is added (byte-identical request body to pre-U1 behavior).
//
// TaskLocal values propagate into unstructured `Task {}` created inside the
// binding scope, which is how they survive the AsyncThrowingStream-wrapped
// adapter streaming paths: the binding wraps the SYNCHRONOUS stream
// construction, and the inner Task inherits the values at creation.
public enum LLMCallContext {
    @TaskLocal public static var surface: String?
    @TaskLocal public static var sessionId: String?
    /// Exact model admitted with the provider/effort/tier tuple at the outer
    /// turn boundary. A downstream adapter may reread canonical routing to
    /// fail closed on corruption, but it must not splice a newer valid picker
    /// generation into an already-admitted turn.
    @TaskLocal public static var admittedModel: String?
    /// Model-visible reasoning depth selected for this call. Chat binds the
    /// per-turn value; background callers inherit their surface preference at
    /// the SwiftNativeLLMClient boundary. Provider adapters consume it when
    /// constructing the wire request.
    @TaskLocal public static var reasoningEffort: String?
    /// OpenAI processing tier for this call. `priority` is the user-facing
    /// Fast mode; nil/default preserves standard processing.
    @TaskLocal public static var serviceTier: String?
    /// Exact provider/auth transport requested for this turn. This remains
    /// distinct from the provider family so `openai` (API key),
    /// `openai_oauth_direct`, and `codex` cannot silently swap accounts.
    @TaskLocal public static var providerId: String?
    /// U1 step 2b/3b (2026-06-10) — stable/dynamic split of the system
    /// prompt, bound by the ChatOrchestration tool/streaming loops alongside
    /// `sessionId`. The Anthropic adapters read it to place a cache_control
    /// breakpoint at the END of the stable segment (persona+pins) instead of
    /// the end of the whole churning sys string, so the persona mass gets
    /// cache READS instead of paying the 1.25x write premium every turn.
    /// Unbound → adapters emit the pre-2b/3b combined-block request shape,
    /// byte-identical to before.
    @TaskLocal public static var systemSegments: SystemPromptSegments?
    /// Test-hermeticity seam (2026-06-11). The vision `attachment_unsupported`
    /// tripwire is emitted from a STATIC method on the `LLMAdapter` default
    /// `completeMessages` flatten — the adapters that actually hit it
    /// (Codex / OpenRouter / non-vision stubs) do NOT carry an instance-level
    /// `telemetryDataRootOverride` (only the four vision-capable adapters do,
    /// and those override `completeMessages` and never reach the tripwire). So
    /// the tripwire's destination is threaded the same way the rest of the
    /// per-call context is: a task-local override that propagates into the
    /// inner stream `Task {}`. Unbound (nil) → the trace resolves through
    /// `PersistenceCore.defaultDataRoot()` exactly as in production. Bound by a
    /// test around the call → the row lands under the test's tmp root and the
    /// LIVE default `traces/events.jsonl` is never touched.
    @TaskLocal public static var traceDataRootOverride: URL?
    /// Seconds the WHOLE turn has left when this provider call starts, bound
    /// by the tool loops around each call.
    ///
    /// User, 2026-09-06: the per-call provider wall (600s) equalled the
    /// interactive/Telegram turn window (600s), so one hung call spent the
    /// entire budget and the reconnect ladder had nothing left to retry with.
    /// The router shortens the wall to fit inside what is left, keeping a
    /// reconnect reserve. Unbound → the configured wall stands unchanged.
    @TaskLocal public static var remainingTurnSeconds: TimeInterval?

    /// Request-scoped lazy-tool allowance for predictive preloads.
    ///
    /// Explicit `tool_load` writes still live in `ActiveToolsStore` and persist
    /// for the session. Mechanical route predictions bind this set only around
    /// the current turn so first-call schemas and dispatch agree without
    /// growing the session's durable active-tool file.
    @TaskLocal public static var turnActiveTools: Set<String>?
}

// MARK: - Provider lifecycle evidence

/// Payload-free evidence emitted by the shared provider router around one real
/// adapter invocation. The call id is minted before the adapter starts and is
/// reused for its terminal phase, so the organism can predict an outcome before
/// observing it instead of inferring provider health after the fact.
public enum LLMCallLifecyclePhase: String, Sendable, Equatable {
    case started
    case succeeded
    case failed
    case cancelled
}

public struct LLMCallLifecycleEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let phase: LLMCallLifecyclePhase
    public let providerId: String
    public let model: String
    public let surface: String
    public let sessionId: String?
    public let turnId: String?
    /// Exact request-scoped reasoning effort presented to the shared provider
    /// router. This is payload-free lifecycle evidence, not a quality claim.
    public let reasoningEffort: String?
    public let streaming: Bool
    public let occurredAt: Date

    public init(
        id: String,
        phase: LLMCallLifecyclePhase,
        providerId: String,
        model: String,
        surface: String,
        sessionId: String?,
        turnId: String?,
        reasoningEffort: String? = nil,
        streaming: Bool,
        occurredAt: Date = Date()
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.phase = phase
        self.providerId = String(providerId.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.model = String(model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.surface = String(surface.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.sessionId = sessionId.map { String($0.prefix(160)) }
        self.turnId = turnId.map { String($0.prefix(120)) }
        self.reasoningEffort = reasoningEffort.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(32))
        }.flatMap { $0.isEmpty ? nil : $0 }
        self.streaming = streaming
        self.occurredAt = occurredAt
    }

    public func terminal(_ phase: LLMCallLifecyclePhase, at date: Date = Date()) -> Self {
        precondition(phase != .started)
        return Self(
            id: id,
            phase: phase,
            providerId: providerId,
            model: model,
            surface: surface,
            sessionId: sessionId,
            turnId: turnId,
            reasoningEffort: reasoningEffort,
            streaming: streaming,
            occurredAt: date
        )
    }
}

public protocol LLMCallLifecycleObserving: Sendable {
    func observeProviderCall(_ event: LLMCallLifecycleEvent) async
}

/// Stable/dynamic split of an assembled system prompt (U1 step 2b/3b).
///
/// INVARIANT: the combined system string handed to the LLM client MUST equal
/// `combined` (the non-empty segments joined by `"\n\n"` in stable →
/// stableSuffix → dynamic order) — the segments are a CACHING-layout hint
/// only, never a content change. Adapters verify this via `reassembles(into:)` before
/// splitting and fall back to the single combined block on any mismatch.
///
/// - `stable`: rarely changes turn-to-turn within a session — persona packet,
///   REM pins, and a session's current lazy tool contract/catalog. Safe to
///   cache_control; loading a different tool set intentionally rewrites it.
/// - `stableSuffix`: appended AFTER `stable` and before `dynamic`. Text that
///   is stable for the REST OF THE SESSION but was not known when `stable`
///   was assembled (e.g. a session-scoped contract that a later turn adds).
///   It rides INSIDE the cached prefix: the breakpoint moves to the end of
///   the suffix, so `stable` stays a strict prefix of the cached mass and one
///   breakpoint covers both. Empty by default → byte-identical to the
///   two-segment shape.
/// - `dynamic`: churns every turn — memory recall (keyed per user message)
///   + rendered session history and other per-turn extras. Must NOT carry a
///   cache breakpoint.
public struct SystemPromptSegments: Sendable, Equatable {
    public let stable: String
    public let stableSuffix: String
    public let dynamic: String

    public init(stable: String, stableSuffix: String = "", dynamic: String) {
        self.stable = stable
        self.stableSuffix = stableSuffix
        self.dynamic = dynamic
    }

    /// The canonical recombination: the non-empty segments joined by
    /// `"\n\n"` in `stable` → `stableSuffix` → `dynamic` order, empty
    /// segments collapsing their separator. This is the exact byte sequence
    /// the legacy combined `systemPrompt` must carry.
    public var combined: String {
        [stable, stableSuffix, dynamic]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// True when these segments reassemble byte-for-byte into `system`.
    /// Adapters gate the block split on this so a stale or mismatched
    /// binding can never change model-visible content.
    public func reassembles(into system: String) -> Bool {
        combined == system
    }
}

/// Which conversation-prefix wire shape the Anthropic adapters emit.
///
/// Lives here (NativeAgentCore) rather than in ProviderRouting so the history
/// projection that BINDS it per turn and the adapters that READ it share one
/// type without a module cycle.
///
/// - `v1Legacy`: the pre-2026-09 layout — identity block carries its own
///   cache_control, the stable block carries a second one, conversation
///   breakpoints only on tool-capable / within-turn-reuse calls, and the
///   previous-request boundary derived from fixed `count - 3` arithmetic.
///   Kept BYTE-IDENTICAL as the rollback arm.
/// - `v2Prefix`: the cross-turn cached-transcript layout — identity is a
///   strict prefix of `stable`, so it carries NO breakpoint of its own and
///   one breakpoint at the end of the stable mass covers both; every turn is
///   treated as a prefix-reuse turn.
///
/// TURN-BOUNDARY RULE: `effective` resolves the shape ONCE, at the history
/// builder's seeding boundary, which then BINDS `override` to the shape it
/// actually seeded and keeps it bound for the whole turn. Everything below
/// that boundary — every provider adapter — reads `override` ONLY, and treats
/// unbound as `.v1Legacy`. Re-deriving the shape from `effective` deeper down
/// is a bug: a turn that seeded no replayed history seeds and binds
/// `.v1Legacy`, and an adapter asking `effective` would answer `.v2Prefix`
/// and emit a differently-shaped request than the one the builder built.
///
/// Resolution order for `effective`: task-local `override` (already bound, or
/// bound by a test) → the `chatConversationPrefixShape` user default →
/// `.v2Prefix` (production default).
public enum ConversationPrefixShape: String, Sendable, Equatable, CaseIterable {
    case v1Legacy
    case v2Prefix

    /// UserDefaults key. Accepts "v1Legacy"/"v2Prefix" and the bare "v1"/"v2".
    public static let defaultsKey = "chatConversationPrefixShape"

    /// Per-turn binding — the ONLY thing adapters may read (unbound →
    /// `.v1Legacy` there). Unbound in `effective` → the user default, then
    /// `.v2Prefix`.
    @TaskLocal public static var override: ConversationPrefixShape?

    /// Pure, injectable parser for the persisted value.
    public static func parse(_ raw: String?) -> ConversationPrefixShape? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("v1") { return .v1Legacy }
        if raw.hasPrefix("v2") { return .v2Prefix }
        return nil
    }

    public static var effective: ConversationPrefixShape {
        if let override { return override }
        if let stored = parse(UserDefaults.standard.string(forKey: defaultsKey)) {
            return stored
        }
        return .v2Prefix
    }
}

/// Where the current turn begins inside the array handed to the adapter.
///
/// The adapters need ONE index to place the cross-turn cache breakpoint: the
/// current turn's user message. Everything strictly before it is the prefix
/// the next turn replays verbatim, so the last assistant message before it is
/// the read the next turn is built on.
///
/// The seeding layer already computes this exactly (`Seed.currentUserIndex`).
/// The adapter cannot re-derive it reliably: replayed history carries archived
/// `system` blocks of its own, so "the last system message" is NOT a
/// dependable marker for where the current turn starts — and when the turn's
/// volatile block is empty, or the model has no mid-conversation system
/// support, the seed emits no trailing system message at all. Binding this is
/// how the adapter stops guessing.
///
/// Unbound → the adapter falls back to a conservative trailing-system-run
/// scan and, when even that is ambiguous, places NO cross-turn marker rather
/// than a wrong one.
public enum ConversationPrefixBoundary {
    @TaskLocal public static var currentUserIndex: Int?
}

// The single LLM call boundary used by ChatOrchestration, DreamREMCycle, and
// ProviderRouting. Lives in NativeAgentCore so every subsystem that depends on
// NativeAgentCore can see it without taking a transitive dep on DreamREMCycle.
public protocol LLMClient: Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String
    func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) async throws -> String
    /// Tool-aware variant. When `tools` is nil or empty, callers MUST observe
    /// byte-identical request bodies on the wire as the no-tools overload —
    /// the back-compat path is sacred. Default implementation forwards to the
    /// no-tools overload; concrete clients (SwiftNativeLLMClient) override.
    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String
    /// Structured multi-turn variant for proper tool_use/tool_result loops.
    /// Default implementation below flattens for adapters that only implement
    /// the prompt API; SwiftNativeLLMClient overrides and routes to provider
    /// adapters that can emit canonical structured messages. `surface` pins
    /// provider/model selection to the calling surface's active.json
    /// preference (chat / executions / dream / telegram...); the prior
    /// non-surface entry point was collapsed into this one (tightness sweep
    /// 2026-07-17 — it had no production callers, only forwarders/defaults).
    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured streaming variant for tool-capable chat surfaces. Providers
    /// with native structured SSE support yield text deltas and tool-call
    /// events as they arrive; providers without it fall back to
    /// `completeMessages` and emit the completed text as one delta.
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>
}

extension LLMClient {
    /// Surface-aware variant. Non-chat callers (executions, dream, REM,
    /// telegram) pass their own surface so the dispatch layer's active.json
    /// provider selection honors the right surface. Default implementation
    /// delegates for clients that are not surface-aware.
    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model)
    }

    /// Default implementation forwards to the no-tools overload so existing
    /// adapters keep compiling. Concrete clients with tool routing override.
    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model)
    }
}

/// JSON Schema descriptor for a single tool the LLM is allowed to call. Lives
/// in NativeAgentCore (no PersistenceCore dep) so the `parameters` JSON Schema
/// body is stored as raw canonical-JSON bytes rather than a duplicated
/// JSONValue ADT. Adapters that send tools (OpenAI Responses, Anthropic
/// Messages) deserialize the bytes back into a `[String: Any]` and embed.
public struct LLMToolSchema: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    /// Canonical JSON bytes of the JSON-Schema object describing the tool's
    /// arguments. Build with
    /// `try JSONSerialization.data(withJSONObject: schemaDict)`.
    public let parametersJSON: Data
    /// Anthropic `defer_loading` (beta `mid-conversation-tool-changes-2026-07-01`).
    ///
    /// A tool declared with `defer_loading: true` is DECLARED in the request's
    /// `tools` array — so it is part of the cached prefix and can be referenced
    /// by name — but is NOT offered to the model until a `tool_addition` block
    /// surfaces it. That is the whole point of the mid-conversation tool-change
    /// lane: the array stays byte-identical turn to turn while the offered set
    /// changes in the message body, behind the cache breakpoint.
    ///
    /// FALSE for every other lane and every other provider, so a request that
    /// never sets it is byte-identical to the pre-2026-09 wire.
    public let deferLoading: Bool

    public init(
        name: String,
        description: String,
        parametersJSON: Data,
        deferLoading: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.deferLoading = deferLoading
    }

    /// The same schema with the deferred-loading flag set (or cleared).
    public func deferringLoad(_ deferLoading: Bool = true) -> LLMToolSchema {
        LLMToolSchema(
            name: name,
            description: description,
            parametersJSON: parametersJSON,
            deferLoading: deferLoading
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, parametersJSON, deferLoading
    }

    /// Hand-rolled so a persisted schema written before `deferLoading` existed
    /// still decodes (absent → false) and a schema that does not defer encodes
    /// byte-identically to the pre-flag shape.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.parametersJSON = try container.decode(Data.self, forKey: .parametersJSON)
        self.deferLoading = try container.decodeIfPresent(Bool.self, forKey: .deferLoading) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parametersJSON, forKey: .parametersJSON)
        if deferLoading { try container.encode(true, forKey: .deferLoading) }
    }
}

/// One Anthropic mid-conversation tool change (beta
/// `mid-conversation-tool-changes-2026-07-01`).
///
/// A MESSAGE-LEVEL field rather than an `LLMContentBlock` case on purpose:
/// every adapter in this repo switches exhaustively over `LLMContentBlock`, so
/// a new case there would be a twelve-file edit across providers that can
/// never carry one of these. Carried on `LLMMessage.toolChanges`, it is
/// invisible to every encoder that does not opt in, and the ONE lane that
/// emits it (the Anthropic api-key structured lane) reads it explicitly.
///
/// `name` is the PROVIDER-visible tool name — the name as it appears in the
/// request's `tools` array. Referencing a name that is not declared there is a
/// 400, so the producer validates against the array before building these.
public struct LLMToolChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `{"type":"tool_addition","tool":{"type":"tool_reference","name":…}}`
        case addition
        /// `{"type":"tool_removal","tool":{"type":"tool_reference","name":…}}`
        case removal
    }

    public let kind: Kind
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static func addition(_ name: String) -> LLMToolChange {
        LLMToolChange(kind: .addition, name: name)
    }

    public static func removal(_ name: String) -> LLMToolChange {
        LLMToolChange(kind: .removal, name: name)
    }
}

/// Provider-issued tool call surfaced by a structured streaming adapter.
/// `inputJSON` is the raw argument object bytes so ChatOrchestration can parse
/// it with the same JSONValue path used for non-streaming tool calls.
public struct LLMStreamToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let inputJSON: Data

    public init(id: String, name: String, inputJSON: Data) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
    }
}

public enum LLMMessageStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(LLMStreamToolCall)
    /// Liveness signal: the provider is producing NON-user-visible output (an
    /// extended-thinking phase, or tool-argument accumulation) — real activity,
    /// but not reply content. `ProviderStreamGuard` counts it as a yield so its
    /// idle clock doesn't kill a healthy long-reasoning turn (audit #4,
    /// 2026-06-14), while consumers IGNORE it so no empty/placeholder content
    /// leaks into the assistant reply. Replaces the prior `.textDelta("")`
    /// keepalive, which leaked empty deltas into every consumer (a footgun: any
    /// consumer that treats "a delta arrived" as a token-event would mis-fire).
    case keepAlive
}

// MARK: - Multi-turn message structure (proper tool_use / tool_result blocks)
//
// HOTFIX 2026-06-03 conversation-shape: the single-prompt API
// (`complete(prompt:String, ...)`) can't represent a tool-use loop properly.
// When the model emits a tool call and we want to feed the result back, both
// the Anthropic Messages API and the OpenAI Responses API require STRUCTURED
// content blocks (`tool_use` + `tool_result` for Anthropic, `function_call` +
// `function_call_output` items for OpenAI). Appending "Tool X returned: ..."
// as plain text to a growing single prompt doesn't satisfy either contract —
// the model keeps re-emitting tool calls every iteration because it never sees
// the structured result.
//
// `LLMMessage` carries an ordered sequence of structured content blocks per
// role. Adapters that implement `completeMessages(messages:...)` translate
// these into their provider's specific wire shape; the default `complete`
// path stays untouched for non-tool-loop callers.

/// One block of structured content inside an `LLMMessage`. Mirrors the union
/// of Anthropic's content-block types and OpenAI Responses' item types,
/// narrowed to what the tool loop actually needs.
public enum LLMContentBlock: Sendable, Equatable {
    /// Plain text. Used for user input, assistant prose, and system context.
    case text(String)
    /// The assistant invoked a tool. `id` is the provider-issued call id
    /// (Anthropic: `toolu_...`, OpenAI: the function_call item's `call_id`)
    /// and MUST be echoed in the matching `toolResult` block so the provider
    /// can pair the call to its result.
    case toolUse(id: String, name: String, inputJSON: Data)
    /// The user (i.e., the tool dispatcher) is returning the tool's result.
    /// `toolUseId` MUST match a prior `toolUse.id` from the same conversation.
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// A native image attachment on the current user turn. Per-turn DYNAMIC
    /// content carried on the CURRENT user message only — image blocks MUST
    /// NEVER enter `systemPrompt`/`systemSegments` (would churn the cached
    /// prefix every turn) and MUST NOT be re-sent on later turns (history is
    /// persisted as metadata only, no base64). Adapters that support vision
    /// (Anthropic, OpenAI) encode this as their provider-native image block.
    /// The default-flatten path is the tripwire for non-vision adapters
    /// (Codex/OpenRouter) — it emits an honest note instead of pretending.
    case image(mediaType: String, base64: String, name: String?, byteSize: Int)
}

/// One conversation message. The TURN-LEVEL system prompt is still passed
/// separately via the `system:` arg (both providers' canonical request
/// shape). `.system` here is the MID-CONVERSATION variant: a system message
/// positioned inside the message array, so per-turn volatile context can sit
/// AFTER the cached transcript prefix instead of churning the front of it.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable { case user, assistant, system }
    public let role: Role
    public let content: [LLMContentBlock]
    /// Anthropic `clear_at: "next_user_message"` — the provider drops this
    /// message from the conversation once the next user message arrives, so a
    /// turn-scoped instruction never becomes permanent transcript. VALID ONLY
    /// ON `.system`: the initializer forces it to false for every other role,
    /// so no encoder has to re-check the invariant. Requires the
    /// `mid-conversation-system-clear-at-2026-08-21` beta, which the adapter
    /// adds per-request exactly when a flagged message is present, and a model
    /// whose catalog row says `supportsMidConversationSystemClearAt`.
    public let turnScopedClearAtNextUserMessage: Bool
    /// Anthropic `tool_addition` / `tool_removal` content blocks, carried as a
    /// message-level field (see `LLMToolChange`). VALID ONLY ON `.system` AND
    /// ONLY WHEN NOT TURN-SCOPED: a `clear_at` message is text-only and returns
    /// a 400 if it carries a tool-change block, so the initializer clears the
    /// list for every other shape and no encoder has to re-check the invariant.
    /// Requires the `mid-conversation-tool-changes-2026-07-01` beta, which the
    /// Anthropic adapters add per-request exactly when a message carries one,
    /// and a model whose catalog row says `supportsMidConversationToolChanges`.
    public let toolChanges: [LLMToolChange]

    public init(
        role: Role,
        content: [LLMContentBlock],
        turnScopedClearAtNextUserMessage: Bool = false,
        toolChanges: [LLMToolChange] = []
    ) {
        self.role = role
        self.content = content
        self.turnScopedClearAtNextUserMessage =
            role == .system ? turnScopedClearAtNextUserMessage : false
        self.toolChanges =
            (role == .system && !self.turnScopedClearAtNextUserMessage) ? toolChanges : []
    }

    /// A mid-conversation system message that carries ONLY tool-change blocks.
    /// Never turn-scoped (the API rejects that pairing).
    public static func toolChanges(_ changes: [LLMToolChange]) -> LLMMessage {
        LLMMessage(role: .system, content: [], toolChanges: changes)
    }

    /// Convenience: build a pure-text user message.
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }
    /// Convenience: build a pure-text MID-CONVERSATION system message.
    /// `clearAtNextUserMessage` marks it turn-scoped (see the flag's doc).
    public static func system(
        _ text: String,
        clearAtNextUserMessage: Bool = false
    ) -> LLMMessage {
        LLMMessage(
            role: .system,
            content: [.text(text)],
            turnScopedClearAtNextUserMessage: clearAtNextUserMessage
        )
    }
    /// Convenience: build a pure-text assistant message.
    public static func assistantText(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)])
    }
    /// Build a user message with native image blocks FIRST, then optional
    /// trailing text. Anthropic-recommended ordering. Empty text drops the
    /// trailing text block — providers that support image-only user messages
    /// (Anthropic, OpenAI Responses) accept this; the default-flatten tripwire
    /// path always has an honest-note text block prepended.
    public static func userWithImages(_ text: String, images: [LLMContentBlock]) -> LLMMessage {
        let trimmed = text
        let trailing: [LLMContentBlock] = trimmed.isEmpty ? [] : [.text(trimmed)]
        return LLMMessage(role: .user, content: images + trailing)
    }
}

extension LLMClient {
    /// Structured multi-turn variant. Default implementation FLATTENS messages
    /// to a single prompt string and delegates to the existing
    /// `complete(...tools:)` overload — back-compat for adapters that haven't
    /// been updated to the structured shape (api-key, OpenRouter, Codex).
    /// SwiftNativeLLMClient + the two OAuth-direct adapters override. `surface`
    /// is accepted for routing parity; the flatten fallback does not itself
    /// vary by surface (the concrete client threads it into provider routing).
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // Conservative flatten: just concatenate text blocks per role with
        // role-prefix lines. Tool blocks become inline annotations so a
        // non-tool-aware adapter doesn't drop them silently.
        var parts: [String] = []
        var imageCount = 0
        for m in messages {
            let prefix: String
            switch m.role {
            case .user: prefix = "USER:"
            case .assistant: prefix = "ASSISTANT:"
            case .system: prefix = "SYSTEM:"
            }
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
                    // TRIPWIRE: this adapter has no native vision wiring.
                    // Drop bytes (NEVER stringify base64), count for the note.
                    imageCount += 1
                }
            }
        }
        var combined = parts.joined(separator: "\n")
        if imageCount > 0 {
            let note = "[NOTE TO ASSISTANT: the user attached \(imageCount) image(s) but the active provider/model cannot see images. Tell the user honestly that you could not view the attached image(s) — do NOT guess or pretend to describe them.]"
            combined = combined.isEmpty ? note : note + "\n" + combined
        }
        return try await complete(prompt: combined, system: system, model: model, tools: tools)
    }

    /// Default streaming: run the (possibly flattened) `completeMessages`
    /// surface variant and emit its completed text as one delta. Providers
    /// with native structured SSE override this.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let reply = try await completeMessages(
                        messages: messages,
                        system: system,
                        model: model,
                        surface: surface,
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
}

// Streaming sibling of LLMClient. Lives in NativeAgentCore (same reasoning as
// LLMClient) so ProviderRouting can declare conformance without taking a
// circular dep on ChatOrchestration. ChatOrchestration adds the higher-level
// streamTurn engine that consumes this in TurnStreamEvent terms.
public protocol StreamingLLMClient: Sendable {
    func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error>
    func stream(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) -> AsyncThrowingStream<String, Error>
}

extension StreamingLLMClient {
    /// Surface-aware streaming variant. See `LLMClient.complete(...surface:)`.
    public func stream(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) -> AsyncThrowingStream<String, Error> {
        stream(prompt: prompt, system: system, model: model)
    }
}

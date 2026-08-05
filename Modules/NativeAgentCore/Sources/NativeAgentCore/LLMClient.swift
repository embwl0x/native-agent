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
/// `combined` (i.e. `stable + "\n\n" + dynamic`, empty segments collapsing
/// the separator) — the segments are a CACHING-layout hint only, never a
/// content change. Adapters verify this via `reassembles(into:)` before
/// splitting and fall back to the single combined block on any mismatch.
///
/// - `stable`: rarely changes turn-to-turn within a session — persona packet,
///   REM pins, and a session's current lazy tool contract/catalog. Safe to
///   cache_control; loading a different tool set intentionally rewrites it.
/// - `dynamic`: churns every turn — memory recall (keyed per user message)
///   + rendered session history and other per-turn extras. Must NOT carry a
///   cache breakpoint.
public struct SystemPromptSegments: Sendable, Equatable {
    public let stable: String
    public let dynamic: String

    public init(stable: String, dynamic: String) {
        self.stable = stable
        self.dynamic = dynamic
    }

    /// The canonical recombination: `stable + "\n\n" + dynamic`, with empty
    /// segments collapsing the separator. This is the exact byte sequence
    /// the legacy combined `systemPrompt` must carry.
    public var combined: String {
        if stable.isEmpty { return dynamic }
        if dynamic.isEmpty { return stable }
        return stable + "\n\n" + dynamic
    }

    /// True when these segments reassemble byte-for-byte into `system`.
    /// Adapters gate the block split on this so a stale or mismatched
    /// binding can never change model-visible content.
    public func reassembles(into system: String) -> Bool {
        combined == system
    }
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

    public init(name: String, description: String, parametersJSON: Data) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
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

/// One conversation message. The role is "user", "assistant", or (rarely)
/// "system" — but system prompts are passed separately via the `system:`
/// arg, not as a message, to match both providers' canonical request shape.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable { case user, assistant }
    public let role: Role
    public let content: [LLMContentBlock]

    public init(role: Role, content: [LLMContentBlock]) {
        self.role = role
        self.content = content
    }

    /// Convenience: build a pure-text user message.
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
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

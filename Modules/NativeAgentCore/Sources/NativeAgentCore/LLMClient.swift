import Foundation

// Blueprint: | `LLMClient.swift` | `LLMClient` named completion and structured streaming; request context, prompt layout, offered schemas and message/stream contracts |

// MARK: - LLMCallContext (request scope)
//
// Task-local context carries the calling surface for telemetry and session
// identity for prompt-cache routing. Unbound surfaces are "unknown"; sessionless
// Workshop calls use a stable scope, other sessionless calls use their turn id,
// and calls without any scope omit the cache hint.
// Bindings wrap synchronous stream construction so inner Tasks inherit them.
public enum LLMCallContext {
    /// The shared router owns the admitted call's wall and cancels its process.
    @TaskLocal public static var wallOwned = false
    /// The admitted turn's client, for thoughts made by its owned code.
    @TaskLocal public static var client: (any LLMClient)?
    @TaskLocal public static var toolCapabilityNote: (@Sendable (String) -> Void)?
    @TaskLocal public static var turnTokenBudget: TurnTokenBudget?
    @TaskLocal public static var surface: String?
    @TaskLocal public static var purpose: String = "other"
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
    /// Anthropic caches the stable segment; unbound calls use one combined block.
    @TaskLocal public static var systemSegments: SystemPromptSegments?
    /// Per-call trace root; nil resolves through `PersistenceCore.defaultDataRoot()`.
    @TaskLocal public static var traceDataRootOverride: URL?
    /// The tools this turn offers by name: `app` on her chat, a lane's own
    /// declared list on an ephemeral turn.
    @TaskLocal public static var turnActiveTools: Set<String>?
}

/// Stable/dynamic split of an assembled system prompt.
///
/// INVARIANT: the combined system string handed to the LLM client MUST equal
/// `combined` (the non-empty segments joined by `"\n\n"` in stable → dynamic
/// order) — the segments are a CACHING-layout hint
/// only, never a content change. Adapters verify this via `reassembles(into:)` before
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

    /// The canonical recombination: the non-empty segments joined by
    /// `"\n\n"` in `stable` → `dynamic` order, empty
    /// segments collapsing their separator. This is the exact byte sequence
    /// the combined `systemPrompt` must carry.
    public var combined: String {
        [stable, dynamic]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Block texts concatenate to the combined prompt; separators belong to the preceding block.
    public var textBlockLayout: (texts: [String], lastStableIndex: Int) {
        var texts = [stable].filter { !$0.isEmpty }
        let lastStableIndex = texts.count - 1
        if !dynamic.isEmpty { texts.append(dynamic) }
        for index in texts.indices.dropLast() { texts[index] += "\n\n" }
        return (texts, lastStableIndex)
    }

    /// True when these segments reassemble byte-for-byte into `system`.
    /// Adapters gate the block split on this so a stale or mismatched
    /// binding can never change model-visible content.
    public func reassembles(into system: String) -> Bool {
        combined.utf8.elementsEqual(system.utf8)
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
/// The adapter cannot re-derive it from roles: tool results within a turn are
/// user messages too. Context leads its own user turn on every provider, so
/// there is no separate system message to mark the boundary.
///
/// Unbound calls have no seeded cross-turn boundary and receive no such marker.
public enum ConversationPrefixBoundary {
    @TaskLocal public static var currentUserIndex: Int?
}

// The single LLM call boundary used by ChatOrchestration, DreamREMCycle, and
// ProviderRouting. Lives in NativeAgentCore so every subsystem that depends on
// NativeAgentCore can see it without taking a transitive dep on DreamREMCycle.
public protocol LLMClient: Sendable {
    /// Named completion retains the calling route, purpose and optional tool offer.
    /// Nil or empty tools preserve the existing no-tools wire request.
    func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String,
        purpose: String,
        tools: [LLMToolSchema]?
    ) async throws -> String
    /// Structured streaming variant for tool-capable chat surfaces. Providers
    /// with native structured SSE support yield text deltas and tool-call
    /// events as they arrive; complete-only clients flatten messages into
    /// the named completion and emit the completed text as one delta.
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>

    /// The provider a `streamMessages` call for `model` on `surface` would be
    /// served by right now, under the caller's bound `LLMCallContext` — the
    /// same resolution the call runs, so a caller choosing how to talk to the
    /// adapter reads its answer instead of guessing from a model prefix. Nil
    /// when the client does not route (test doubles) or the call would fail
    /// before reaching any adapter.
    func servingProviderID(model: String?, surface: String) async -> String?
}

extension LLMClient {
    /// Clients that do not route to provider adapters serve no provider.
    public func servingProviderID(model: String?, surface: String) async -> String? {
        nil
    }
}

/// Offered JSON schema and its local effect declaration. Policy fields never
/// enter CodingKeys; adapters retain the same provider-visible contract.
public struct LLMToolSchema: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    /// Canonical JSON bytes of the JSON-Schema object describing the tool's
    /// arguments. Build with
    /// `try JSONSerialization.data(withJSONObject: schemaDict)`.
    public let parametersJSON: Data
    /// The class its declaration gives it; nil on a decoded wire copy.
    public let toolClass: ToolClass?
    public let reach: ToolReach
    public let capabilities: Set<String>
    public let effectInputPolicy: ToolEffectInputPolicy

    public init(
        name: String,
        toolClass: ToolClass? = nil,
        reach: ToolReach = .hers,
        capabilities: Set<String>? = nil,
        effectInputPolicy: ToolEffectInputPolicy = .fixed,
        description: String,
        parametersJSON: Data
    ) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.toolClass = toolClass
        self.reach = reach
        self.capabilities = capabilities ?? toolClass?.baseCapabilities ?? []
        self.effectInputPolicy = effectInputPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, parametersJSON
    }

    /// The offered contract; the class is policy, not part of it.
    public static func == (lhs: LLMToolSchema, rhs: LLMToolSchema) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
            && lhs.parametersJSON == rhs.parametersJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.parametersJSON = try container.decode(Data.self, forKey: .parametersJSON)
        self.toolClass = nil
        self.reach = .his
        self.capabilities = []
        self.effectInputPolicy = .fixed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parametersJSON, forKey: .parametersJSON)
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

public enum LLMToolBoundaryReason: String, Sendable, Equatable {
    case repeatedBlock, repeatedAction, fabricatedResult, postCallProse, outputLimit, incompleteCall, interrupted
    /// The person steered mid-reply: the stream was cut at the next delta so their words land now.
    case steered
    /// The provider's safety layer stopped the reply (stop_reason refusal).
    case refusal

    /// What a provider's own stop reason says ended the reply, before any
    /// guess from where the text stopped; nil for a reply that ended itself.
    public init?(stopReason: String?) {
        switch stopReason {
        case "max_tokens": self = .outputLimit
        case "refusal": self = .refusal
        default: return nil
        }
    }
}

public enum LLMMessageStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(LLMStreamToolCall)
    /// Complete calls survive; the tail after them was withheld by the client.
    case toolBoundary(LLMToolBoundaryReason)
    /// Presentation only: the message ended, but the response remains open.
    case replyTextSettled(Bool)
    /// Provider activity advances liveness without adding user-visible reply content.
    case keepAlive
}

// MARK: - Multi-turn message structure (proper tool_use / tool_result blocks)
//
// Tool loops carry structured calls and results; adapters encode the provider wire shape.

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
/// positioned inside the message array. Per-turn context does not use this
/// role: it is sent and replayed as leading text of its user turn.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable { case user, assistant, system }
    public let role: Role
    public let content: [LLMContentBlock]

    public init(
        role: Role,
        content: [LLMContentBlock]
    ) {
        self.role = role
        self.content = content
    }

    /// Convenience: build a pure-text user message.
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }
    /// Convenience for callers supplying a conversation-level system role.
    /// Turn context always rides the current user message.
    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: [.text(text)])
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
    /// Clients without structured transport flatten messages into the named completion.
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
                    let flattened = try llmCompatibilityPrompt(messages: messages) { role in
                        switch role {
                        case .user: "USER:"
                        case .assistant: "ASSISTANT:"
                        case .system: "SYSTEM:"
                        }
                    }
                    let reply = try await complete(prompt: flattened.text, system: system, model: model,
                        surface: surface, purpose: LLMCallContext.purpose, tools: tools)
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

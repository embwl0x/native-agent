import Foundation

// Blueprint: | `LLMClient.swift` | `LLMClient`, `LLMToolSchema`: completion, streams and local tool effect declarations |

/// System segments are a cache-layout hint: stable then dynamic must reassemble byte-for-byte into the combined prompt. Only stable content carries a cache
/// breakpoint; dynamic turn context must not.
public struct SystemPromptSegments: Sendable, Equatable {
    public let stable: String
    public let dynamic: String

    public init(stable: String, dynamic: String) {
        self.stable = stable
        self.dynamic = dynamic
    }

    /// Nonempty segments join in stable-to-dynamic order with exactly two newlines; the combined prompt must carry those bytes.
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

    /// True when these segments reassemble byte-for-byte into `system`. Adapters gate the block split on this so a stale or mismatched binding can never change
    /// model-visible content.
    public func reassembles(into system: String) -> Bool {
        combined.utf8.elementsEqual(system.utf8)
    }
}

// Keep the shared LLM boundary below its callers so they do not acquire a dependency on DreamREMCycle.
public protocol LLMClient: Sendable {
    /// Named completion retains the calling route, purpose and optional tool offer. Nil or empty tools preserve the existing no-tools wire request.
    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String
    /// Structured streaming variant for tool-capable chat surfaces. Providers with native structured SSE support yield text deltas and tool-call events as they
    /// arrive; complete-only clients flatten messages into the named completion and emit the completed text as one delta.
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>

    /// The provider a `streamMessages` call for `model` would be served by right now for `call` — the same
    /// resolution the call runs, so a caller choosing how to talk to the adapter reads its checked answer instead of guessing from a model prefix. Unavailable
    /// routing preserves the owner's error before a grammar is chosen.
    func servingProviderID(model: String?, call: LLMCall) async throws -> String

    /// The output cap this request's adapter will put on the wire. Zero means that transport sends no output-cap field, not an unknown model limit.
    func requestOutputTokens(model: String, call: LLMCall) async throws -> Int
}

extension LLMClient {
    public func requestOutputTokens(model: String, call: LLMCall) async throws -> Int {
        throw LLMErrorForOutputMeasurement.unavailable
    }
    public func servingProviderID(model: String?, call: LLMCall) async throws -> String {
        throw LLMErrorForOutputMeasurement.providerUnavailable
    }
}

private enum LLMErrorForOutputMeasurement: LocalizedError {
    case unavailable, providerUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "This model client does not expose its request output allowance; context admission is unavailable."
        case .providerUnavailable: "This model client does not expose its serving provider; tool protocol admission is unavailable."
        }
    }
}

/// Offered JSON schema and its local effect declaration. Policy fields never enter CodingKeys; adapters retain the same provider-visible contract.
public struct LLMToolSchema: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    /// Retain canonical JSON-Schema bytes so every adapter offers the same argument contract.
    public let parametersJSON: Data
    /// The class its declaration gives it; nil on a decoded wire copy.
    public let toolClass: ToolClass?
    public let reach: ToolReach
    public let capabilities: Set<String>
    public let effectInputPolicy: ToolEffectInputPolicy
    /// Local app/axis declaration; absent for tools without a Mac integration and never sent to providers.
    public let macIntegration: MacIntegrationAccess?

    public init(
        name: String,
        toolClass: ToolClass? = nil,
        reach: ToolReach = .agent,
        capabilities: Set<String>? = nil,
        effectInputPolicy: ToolEffectInputPolicy = .fixed,
        macIntegration: MacIntegrationAccess? = nil,
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
        self.macIntegration = macIntegration
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
        self.reach = .person
        self.capabilities = []
        self.effectInputPolicy = .fixed
        self.macIntegration = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parametersJSON, forKey: .parametersJSON)
    }
}

/// Provider-issued tool call surfaced by a structured streaming adapter. `inputJSON` is the raw argument object bytes so ChatOrchestration can parse it with
/// the same JSONValue path used for non-streaming tool calls.
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

/// A call's input while it streams, before the call is whole: who is called and how much is written. Movement only, never a call to run.
public struct LLMStreamCallInput: Sendable, Equatable {
    /// The input's first bytes are enough to read which action an `app` call runs; the rest never leaves the adapter.
    public static let headLimit = 256
    public let name: String
    public let head: String
    /// UTF-8 bytes of input written so far.
    public let bytes: Int

    public init(name: String, input: some Collection<UInt8>) {
        self.name = name
        head = String(decoding: input.prefix(Self.headLimit), as: UTF8.self)
        bytes = input.count
    }
}

public enum LLMToolBoundaryReason: String, Sendable, Equatable {
    case repeatedBlock, repeatedAction, fabricatedResult, postCallProse, outputLimit, incompleteCall, interrupted
    /// The person steered mid-reply: the stream was cut at the next delta so their words land now.
    case steered
    /// The provider's safety layer stopped the reply (stop_reason refusal).
    case refusal

    /// What a provider's own stop reason says ended the reply, before any guess from where the text stopped; nil for a reply that ended itself.
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
    /// A named call's input is streaming; like keepAlive it adds no reply content, and it says what is being written.
    case callInput(LLMStreamCallInput)
}

// MARK: - Multi-turn message structure (proper tool_use / tool_result blocks)
// Tool loops retain structured calls and results; each adapter owns its provider wire shape.

public enum LLMContentBlock: Sendable, Equatable {
    case text(String)
    /// Echo the provider-issued tool call ID in the matching result so the provider can pair them within the conversation.
    case toolUse(id: String, name: String, inputJSON: Data)
    /// A tool result must name a prior toolUse ID in the same conversation.
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// Images belong only on the current user message: putting them in system context churns the cached prefix, and replaying their bytes on later turns
    /// duplicates input. Persist history as metadata; non-vision adapters disclose the missing image capability.
    case image(mediaType: String, base64: String, name: String?, byteSize: Int)
}

/// Conversation-level system messages stay separate from turn context, which leads its own user message on every provider.
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

    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }
    /// Turn context always rides the current user message, never a conversation-level system message.
    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: [.text(text)])
    }
    public static func assistantText(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)])
    }
    /// Put image blocks before optional text as Anthropic recommends. Image-only requests are valid for vision adapters; non-vision flattening prepends a
    /// disclosure.
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
        tools: [LLMToolSchema]?,
        call: LLMCall
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
                        tools: tools, call: call)
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

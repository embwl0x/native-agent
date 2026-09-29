import ChatToolParsing
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// How the streaming tool loop offers tools to a provider and reads its output
/// back as prose + tool calls. The loop owns everything else (budgets, bounces,
/// dispatch, recovery); the codec owns only the wire encoding of tool calls.
enum ToolCallCodec: Sendable, Equatable {
    /// Provider-native tool calling: `tools[]` on the request, calls as
    /// `.toolCall` stream events. XML/JSON markers in the text are still
    /// held back from the surface and parsed when a round streamed no call.
    case native
    /// A transport with no tool calling (Codex CLI, `buffered_text`). The
    /// offered array still reaches the client, whose capability admission
    /// records the text-only note, and the adapter never forwards it; the
    /// stream is one text delta read exactly as `.native` reads text.
    case none
    /// The text-compatibility marker protocol (`TextMarkerCodec`): no
    /// `tools[]`, the catalog as prose in the system prompt, calls as markers
    /// in the reply, each round's results as one user message. The Claude
    /// subscription speaks it.
    case textMarkers

    /// Chosen from the provider the client resolves for the turn's calls
    /// (`LLMClient.servingProviderID`). Nil — a client that does not route,
    /// or a call that fails before any adapter — keeps the native reading.
    static func forProvider(_ providerID: String?) -> ToolCallCodec {
        guard let providerID, !providerID.isEmpty else { return .native }
        if speaksTextMarkers(providerID) { return .textMarkers }
        return ProviderToolCapability.supportsTools(providerID: providerID) ? .native : .none
    }

    /// An Anthropic-wire provider that cannot take a native tools[] array
    /// (the Claude subscription, NativeToolCapability) speaks tool markers in
    /// text.
    static func speaksTextMarkers(_ providerID: String) -> Bool {
        providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .hasPrefix("anthropic_")
            && !NativeToolCapability.providerSupportsNativeTools(providerID)
    }

    /// The `tools` argument for this round's request.
    func requestTools(_ schemas: [LLMToolSchema]) -> [LLMToolSchema]? {
        switch self {
        case .native, .none: schemas.isEmpty ? nil : schemas
        // The catalog rides the system prompt.
        case .textMarkers: nil
        }
    }

    /// Moves the prose in `pending` that can safely reach the surface out of
    /// it: everything before the earliest potential call marker, else all
    /// but a 16-character tail so a marker split across chunks is caught
    /// before any part of it renders. Returns "" when nothing is safe yet.
    func releasableProse(holding pending: inout String) -> String {
        if self == .textMarkers {
            return TextMarkerCodec.releasableProse(holding: &pending, force: false)
        }
        if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: pending) {
            let safe = String(pending[..<marker.lowerBound])
            pending = String(pending[marker.lowerBound...])
            return safe
        }
        // Hold only a tail that could still grow into a marker ("<to",
        // "**tool c"); plain prose goes out now. A fixed 16-character hold
        // froze the reply's last words until the provider closed the stream
        // (User 09-26: seconds of "hang" at the last paragraph).
        let held = Self.markerPrefixTailLength(pending)
        let split = pending.index(pending.endIndex, offsetBy: -held)
        let safe = String(pending[..<split])
        pending = String(pending[split...])
        return safe
    }

    private static let markerStarts = ["<tool", "tool_use name=\"", "**tool call", "__tool call", "tool call:", "```", "~~~"]

    /// Length of the longest suffix of `text` that is a proper start of a marker.
    private static func markerPrefixTailLength(_ text: String) -> Int {
        let longest = markerStarts.map(\.count).max() ?? 0
        for length in stride(from: min(longest, text.count), to: 0, by: -1) {
            let tail = text.suffix(length).lowercased()
            if markerStarts.contains(where: { $0.hasPrefix(tail) }) { return length }
        }
        return 0
    }

    /// What of the held-back tail reaches the surface when the round calls
    /// tools. The marker protocol shows none of it: from the first marker on
    /// it is call encoding, and text after the last one was written before
    /// any result existed.
    func proseReleasedAtDispatch(_ pending: String) -> String {
        self == .textMarkers ? "" : ToolCallParser.stripToolUseMarkers(pending)
    }

    /// Prose before the earliest potential call marker — what a stopped,
    /// failed or cut-off turn keeps. The marker protocol also cuts at
    /// Claude's own `<function_calls>` / `<invoke>` form.
    func visiblePrefix(in text: String) -> String {
        ToolCallParser.visiblePrefix(in: text, invoke: self == .textMarkers)
    }

    /// One streamed tool-call event as a call to dispatch; nil for a call
    /// the loop ignores. Arguments that are not a JSON object fail the round.
    func decode(_ call: LLMStreamToolCall) throws -> ParsedToolCall? {
        // Nothing offered, so nothing streamed is a call.
        if self == .textMarkers { return nil }
        guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
        guard let parsed = try? JSONValue.parse(call.inputJSON),
              case .object(let input) = parsed else {
            throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
        }
        return ParsedToolCall(id: call.id, name: call.name, input: input)
    }

    /// A finished round's executable calls: the streamed ones, else any
    /// recovered from the round's text. `schemas` is the round's catalog,
    /// which marker-argument repair reads.
    func roundCalls(
        streamed: [ParsedToolCall], text: String, schemas: [LLMToolSchema]
    ) -> [ParsedToolCall] {
        switch self {
        case .native, .none:
            ToolCallParser.executableCalls(streamed.isEmpty ? ToolCallParser.parse(text) : streamed)
        case .textMarkers:
            TextMarkerCodec(schemas: schemas, turnActiveTools: []).calls(in: text)
        }
    }
}

import ChatToolParsing
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `ToolCallCodec.swift` | `ToolCallCodec`: provider tool offerings, streamed prose release and native/text-marker call decoding; the turn loop owns dispatch and budgets |

/// How the streaming tool loop offers tools to a provider and reads its output
/// back as prose + tool calls. The loop owns everything else (budgets, bounces,
/// dispatch, recovery); the codec owns the wire encoding of calls and results.
enum ToolCallCodec: Sendable, Equatable {
    /// Provider-native tool calling: `tools[]` on the request, calls as
    /// `.toolCall` stream events. XML/JSON markers in the text are still
    /// held back from the surface and parsed when a round streamed no call.
    case native
    /// A transport with no tool calling (Codex CLI). The
    /// offered array still reaches the client, whose capability admission
    /// records the text-only note, and the adapter never forwards it; the
    /// incremental text is read exactly as `.native` reads text.
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
        switch ProviderToolCapability.wire(providerID: providerID) {
        case .native: return .native
        case .textMarkers: return .textMarkers
        case .unsupported: return .none
        }
    }

    /// The `tools` argument for this round's request.
    func requestTools(_ schemas: [LLMToolSchema]) -> [LLMToolSchema]? {
        switch self {
        case .native, .none: schemas.isEmpty ? nil : schemas
        // The catalog rides the system prompt.
        case .textMarkers: nil
        }
    }

    /// Callers prepare their own prose; call IDs pair the native round by position.
    static func assistantMessage(prose: [LLMContentBlock], calls: [ParsedToolCall], pairedIDs: [String],
                                 markerCodec: TextMarkerCodec?) throws -> LLMMessage {
        let uses: [LLMContentBlock] = markerCodec == nil ? try zip(calls, pairedIDs).map { call, id in
            .toolUse(id: id, name: call.name, inputJSON: try JSONValue.object(call.input).serializedData(pretty: false))
        } : []
        return LLMMessage(role: .assistant, content: prose + uses)
    }

    /// Marker results share one closed carrier; pixels follow it in their original order.
    static func resultBlocks(_ blocks: [LLMContentBlock], toolNames: [String],
                             markerCodec: TextMarkerCodec?) -> [LLMContentBlock] {
        guard let markerCodec else { return blocks }
        var carrier = ""
        var images: [LLMContentBlock] = []
        var index = 0
        for block in blocks {
            guard case .toolResult(_, let content, let isError) = block else {
                images.append(block)
                continue
            }
            markerCodec.appendResult(index: index, toolName: toolNames[index], ok: !isError,
                                     content: content, to: &carrier)
            index += 1
        }
        if index > 0 { markerCodec.closeRound(&carrier) }
        return (carrier.isEmpty ? [] : [.text(carrier)]) + images
    }

    /// Moves the prose in `pending` that can safely reach the surface out of
    /// it: everything before the earliest potential call marker, else all
    /// but a 16-character tail so a marker split across chunks is caught
    /// before any part of it renders. Returns "" when nothing is safe yet.
    func releasableProse(holding pending: inout String) -> String {
        // Keep a split citation in the same pending buffer as split tool text.
        var citationTail = ""
        if let start = pending.range(of: "\u{E200}", options: .backwards),
           pending.range(of: "\u{E201}", range: start.upperBound..<pending.endIndex) == nil {
            citationTail = String(pending[start.lowerBound...])
            pending = String(pending[..<start.lowerBound])
        }
        defer { pending += citationTail }
        pending = ChatRichContentParser.visibleText(pending)
        let heldStarts = [ToolCallParser.earliestPotentialProtocolMarker(in: pending),
                          pending.range(of: "NativeAgent tool result #")].compactMap { $0 }
        if let marker = heldStarts.min(by: { $0.lowerBound < $1.lowerBound }) {
            let safe = String(pending[..<marker.lowerBound])
            pending = String(pending[marker.lowerBound...])
            return ToolCallParser.stripProtocolDebris(safe)
        }
        if self == .textMarkers {
            return ToolCallParser.stripProtocolDebris(
                TextMarkerCodec.releasableProse(holding: &pending))
        }
        // Hold only a tail that could still grow into a marker ("<to",
        // "**tool c"); plain prose goes out now. A fixed 16-character hold
        // froze the reply's last words until the provider closed the stream
        // (User 09-26: seconds of "hang" at the last paragraph).
        let held = Self.markerPrefixTailLength(pending)
        let split = pending.index(pending.endIndex, offsetBy: -held)
        let safe = String(pending[..<split])
        pending = String(pending[split...])
        return ToolCallParser.stripProtocolDebris(safe)
    }

    private static let markerStarts = ToolCallParser.protocolMarkerStarts + ["```", "~~~", "NativeAgent tool result #"]

    /// Length of the longest suffix of `text` that is a proper start of a marker.
    static func markerPrefixTailLength(_ text: String) -> Int {
        let placeholder = text.range(of: #"(?<!\w)_\w*\z"#, options: .regularExpression)
            .map { text.distance(from: $0.lowerBound, to: text.endIndex) } ?? 0
        let longest = markerStarts.map(\.count).max() ?? 0
        for length in stride(from: min(longest, text.count), to: 0, by: -1) {
            let tail = text.suffix(length).lowercased()
            if markerStarts.contains(where: { $0.lowercased().hasPrefix(tail) }) { return max(length, placeholder) }
        }
        return placeholder
    }

    /// What of the held-back tail reaches the surface when the round calls
    /// tools. The marker protocol shows none of it: from the first marker on
    /// it is call encoding, and text after the last one was written before
    /// any result existed.
    func proseReleasedAtDispatch(_ pending: String) -> String {
        self == .textMarkers ? "" : visiblePrefix(in: ToolCallParser.stripToolUseMarkers(pending))
    }

    /// Prose before the earliest potential call marker — what a stopped,
    /// failed or cut-off turn keeps.
    func visiblePrefix(in text: String) -> String {
        ChatRichContentParser.visibleText(ToolCallParser.visiblePrefix(in: text))
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
        streamed: [ParsedToolCall], text: String, schemas: [LLMToolSchema], recordShims: Bool = true
    ) -> [ParsedToolCall] {
        switch self {
        case .native, .none:
            ToolCallParser.executableCalls(streamed.isEmpty ? ToolCallParser.parse(text, recordShims: recordShims) : streamed)
        case .textMarkers:
            TextMarkerCodec(schemas: schemas, turnActiveTools: []).calls(in: text, recordShims: recordShims)
        }
    }
}

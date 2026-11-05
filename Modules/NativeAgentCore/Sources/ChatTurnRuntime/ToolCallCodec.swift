import ChatToolParsing
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `ToolCallCodec.swift` | `ToolCallCodec`; Offered wire grammar; dispatch stays with the loop |

/// The codec owns wire encoding only; the loop owns budgets, refusals, dispatch and recovery.
enum ToolCallCodec: Sendable, Equatable {
    /// Native tool events alone supply executable calls; prose never does.
    case native
    /// Text-only transports forward no tool schemas or executable events; capability admission still records their offered contract.
    case none
    /// The marker protocol carries catalog prose in the system prompt and returns one user result message per round.
    case textMarkers

    /// Resolve from the serving provider's declared capability; unknown capability fails admission rather than guessing native tools.
    static func forProvider(_ providerID: String) throws -> ToolCallCodec {
        switch try ProviderToolCapability.checkedWire(providerID: providerID) {
        case .native: return .native
        case .textMarkers: return .textMarkers
        case .unsupported: return .none
        }
    }

    func requestTools(_ schemas: [LLMToolSchema]) -> [LLMToolSchema]? {
        switch self {
        case .native, .none: schemas.isEmpty ? nil : schemas
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

    // Result bodies stay typed until request encoding so every transport shares the same pointer rule.
    func providerMessages(_ messages: [LLMMessage], records: [TurnEngineResult.ToolDispatchRecord],
                          schemas: [LLMToolSchema], turn: Turn) throws -> [LLMMessage] {
        guard self == .textMarkers else { return messages }
        let marker = TextMarkerCodec(schemas: schemas, turnActiveTools: [], turn: turn)
        return try messages.map { message in
            let names = try message.content.compactMap { block -> String? in
                guard case .toolResult(let id, _, _) = block else { return nil }
                guard let record = records.first(where: { $0.id == id }) else {
                    throw ToolFailureError("Tool result \(id) has no recorded call; repair its turn before sending it.", effects: .none)
                }
                return record.name
            }
            guard !names.isEmpty else { return message }
            return LLMMessage(role: message.role, content: Self.resultBlocks(message.content, toolNames: names, markerCodec: marker))
        }
    }

    /// Withhold possible call markers across chunks so partial encoding cannot reach the surface; release safe preceding prose.
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
        // Hold only a suffix that can still become a marker so ordinary final words do not wait for stream closure.
        let held = Self.markerPrefixTailLength(pending)
        let split = pending.index(pending.endIndex, offsetBy: -held)
        let safe = String(pending[..<split])
        pending = String(pending[split...])
        return ToolCallParser.stripProtocolDebris(safe)
    }

    private static let markerStarts = ToolCallParser.protocolMarkerStarts + ["```", "~~~", "NativeAgent tool result #"]

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

    /// Hide the marker suffix at round-end because it is call encoding or prose written before any result existed.
    func proseReleasedAtDispatch(_ pending: String) -> String {
        self == .textMarkers ? "" : visiblePrefix(in: ToolCallParser.stripToolUseMarkers(pending))
    }

    /// Retain only prose before the first potential marker when a turn stops or fails.
    func visiblePrefix(in text: String) -> String {
        ChatRichContentParser.visibleText(ToolCallParser.visiblePrefix(in: text))
    }

    /// Reject non-object arguments at the round boundary; only offered stream events become dispatchable calls.
    func decode(_ call: LLMStreamToolCall) throws -> ParsedToolCall? {
        // Nothing offered, so nothing streamed is a call.
        if self != .native { return nil }
        guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
        guard let parsed = try? JSONValue.parse(call.inputJSON),
              case .object(let input) = parsed else {
            throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
        }
        return ParsedToolCall(id: call.id, name: call.name, input: input)
    }

    /// Parse finished calls only through this turn's offered transport grammar.
    func roundCalls(
        streamed: [ParsedToolCall], text: String, schemas: [LLMToolSchema], recordShims: Bool = true, turn: Turn?
    ) throws -> [ParsedToolCall] {
        switch self {
        case .native:
            ToolCallParser.executableCalls(streamed)
        case .none:
            []
        case .textMarkers:
            try TextMarkerCodec(schemas: schemas, turnActiveTools: [], turn: turn).calls(in: text, recordShims: recordShims)
        }
    }
}

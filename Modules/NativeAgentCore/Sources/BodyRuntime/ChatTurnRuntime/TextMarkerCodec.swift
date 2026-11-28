import MacNerves
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import SenseCore
// Blueprint: | `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |

/// Keep text-marker encoding and detection together so catalog prose, returned markers and per-round results share one protocol.
/// The loop owns placement and budgets; the codec owns the exact wire grammar.
struct TextMarkerCodec: Sendable {
    let turn: Turn?
    /// Use the turn's declared parameters for typed repair and undeclared-field refusal.
    let schemas: [LLMToolSchema]
    let catalogNames: Set<String>
    /// Bounces name this turn's offered tools first.
    let turnActiveTools: Set<String>

    /// Keep the complete catalog distinct from this round's offered schemas.
    init(schemas: [LLMToolSchema], turnActiveTools: Set<String>, catalogNames: Set<String>? = nil, turn: Turn?) {
        self.turn = turn
        self.schemas = schemas
        self.catalogNames = catalogNames ?? Set(schemas.map(\.name))
        self.turnActiveTools = turnActiveTools
    }

    // MARK: - Calls

    func calls(in text: String, recordShims: Bool = true) throws -> [ParsedToolCall] {
        try ToolCallParser.parse(text, parseInvoke: true, recordShims: recordShims).map { call in
            guard call.undeclaredKeys.isEmpty else { return call }
            guard let descriptor = schemas.first(where: { $0.name == call.name }) else { return call }
            let schema = try descriptor.checkedParameters().objectValue!
            let properties = schema["properties"]?.objectValue
            var input = call.input
            if let properties {
                for (key, raw) in call.invokeRawText {
                    guard properties[key]?.objectValue?["type"] == .string("string") else { continue }
                    input[key] = .string(raw)
                    if recordShims {
                        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L13"), "site":
                            .string("TextMarkerCodec.swift:calls")]), turn: turn)
                    }
                }
            }
            var parsed = ParsedToolCall(id: call.id, name: call.name, input: input)
            // Closed, nonempty property schemas reject undeclared fields; unknown, open, empty and composed schemas permit them.
            let composed = ["oneOf", "anyOf", "allOf"].contains { schema[$0] != nil }
            if let properties, !properties.isEmpty, !composed,
               schema["additionalProperties"] != .bool(true) {
                parsed.undeclaredKeys = input.keys.filter { properties[$0] == nil }.sorted()
            }
            return parsed
        }
    }

    func throughLastMarker(_ text: String) -> String {
        ToolCallParser.throughLastToolMarker(text)
    }

    // MARK: - Holdback

    /// Hold only a possible marker or pseudo-call suffix until round-end disambiguation; release preceding prose immediately.
    /// Preserve partial prefixes across chunks so call encoding cannot leak to the surface.
    static func releasableProse(holding pending: inout String) -> String {
        guard !pending.isEmpty else { return "" }
        let holdFrom: String.Index
        if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pending) {
            holdFrom = r.lowerBound
        } else {
            let tail = min(pending.count, max(16, ToolCallCodec.markerPrefixTailLength(pending)))
            holdFrom = pending.index(pending.endIndex, offsetBy: -tail)
        }
        guard holdFrom > pending.startIndex else { return "" }
        let flush = String(pending[..<holdFrom])
        pending = String(pending[holdFrom...])
        return flush
    }

    // MARK: - Result carrier

    func appendResult(
        index: Int,
        id: String,
        toolName: String,
        isError: Bool,
        content: String,
        to carrier: inout String
    ) throws {
        let callID = try JSONValue.string(id).serialize(pretty: false)
            .replacingOccurrences(of: "<", with: #"\u003c"#)
        let body = markerToolResultContent(content, isError: isError)
        carrier += """

        NativeAgent tool result #\(index + 1) for \(toolName) (call_id: \(callID)):
        \(body)
        """
    }

    /// Close each round's results with continuation guidance in the protocol's marker form. This is the protocol's own wire, written every time
    /// a request encodes its history, so it is no compensation and leaves no receipt.
    func closeRound(_ carrier: inout String) {
        carrier += "\n\nIf work remains, send the next <function_calls> block and end at </function_calls>.\n"
    }

    // MARK: - Bounces

    func malformedCall(in text: String) -> ToolCallProtocolViolation? {
        ToolCallParser.formattedToolCallViolation(
            in: text, toolNames: catalogNames.union(turnActiveTools), parseInvoke: true)
    }

    // MARK: - Catalog carrier

    /// Place the always-on catalog before volatile recall and history so ordinary turns reuse an unchanged provider prefix.
    static func systemLayout(
        baseSystem: String?,
        segments: SystemPromptSegments?,
        context: TurnContext
    ) throws -> (system: String, segments: SystemPromptSegments?) {
        let floorBlock = renderFloor(rows: try catalogSections(
            schemas: context.toolSchemas, names: context.toolsAvailable
        ).floor, appDoor: context.toolSchemas.contains { $0.name == "app" })
        guard let segments,
              let baseSystem,
              segments.reassembles(into: baseSystem) else {
            throw ProviderRoutingError
                .configurationFailed("The text-marker request requires coherent system segments; its offered tool contract was not assembled.")
        }
        let stable = segments.stable.isEmpty
            ? floorBlock
            : segments.stable + "\n\n" + floorBlock
        let reordered = SystemPromptSegments(
            stable: stable,
            dynamic: segments.dynamic
        )
        return (reordered.combined, reordered)
    }

    /// Additional offered descriptors ride in the volatile block without moving the prefix.
    static func volatileCatalogAppendix(for context: TurnContext) throws -> String {
        try catalogSections(schemas: context.toolSchemas, names: context.toolsAvailable).appended
    }

    /// Keep the sorted always-on floor whole and byte-stable in the cached segment.
    /// Session additions retain load order in the volatile block; only that run is capped at 80.
    struct CatalogSections {
        var floor: String
        var appended: String
    }

    static func catalogSections(
        schemas: [LLMToolSchema],
        names: [String]
    ) throws -> CatalogSections {
        let core = SwiftToolDispatcher.alwaysOnCoreNames
        var floorRows: [String] = []
        var appendedRows: [String] = []
        var appendedTotal = 0
        if !schemas.isEmpty {
            // Preserve incoming order when partitioning, but sort the floor here so callers outside the filter still get stable output.
            let floorSchemas = schemas.filter { core.contains($0.name) }
                .sorted { $0.name < $1.name }
            let appendedSchemas = schemas.filter { !core.contains($0.name) }
            appendedTotal = appendedSchemas.count
            let row: (LLMToolSchema) throws -> String = { schema in
                let params = try parameterSummary(schema)
                let suffix = params.isEmpty ? "" : "(\(params))"
                return "- \(schema.name)\(suffix): \(compact(schema.description, limit: 180))"
            }
            floorRows = try floorSchemas.map { schema in
                let parameters = try schema.checkedParameters().serialize(pretty: false)
                return "- \(schema.name): \(schema.description)\n  JSON input schema: \(parameters)"
            }
            appendedRows = try appendedSchemas.prefix(80).map(row)
        } else {
            let floorNames = names.filter { core.contains($0) }.sorted()
            let appendedNames = names.filter { !core.contains($0) }
            appendedTotal = appendedNames.count
            floorRows = floorNames.map { "- \($0)" }
            appendedRows = appendedNames.prefix(80).map { "- \($0)" }
        }
        let omittedToolCount = max(0, appendedTotal - appendedRows.count)
        let disclosure = omittedToolCount > 0
            ? "\n- \(omittedToolCount) more you can call, not listed here."
            : ""
        return CatalogSections(
            floor: floorRows.isEmpty
                ? "- Nothing is callable this turn."
                : floorRows.joined(separator: "\n"),
            appended: ([appendedRows.isEmpty
                ? ""
                : "Also loaded this session (callable now with the same markers):\n" + appendedRows.joined(separator: "\n") + disclosure]
                + schemas.map(\.volatileCatalogAppendix)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
    }

    /// Render through the canonical catalog; folded tools use action identity at the app door. The floor is the protocol itself, laid out
    /// on every request, so it is no compensation and leaves no receipt.
    private static func renderFloor(
        rows renderedRows: String,
        appDoor: Bool
    ) -> String {
        let findLine = appDoor
            ? "open its page with app {\"page\": \"<page>\"} or find its action with app {\"find\": \"<what you want done>\"}."
            : "call a known name directly (calling loads it)."
        let gitLine = appDoor
            ? ""
            : "Do not ask for raw shell/git commands unless a shell action is explicitly listed."
        return """
        \(AnthropicOAuthTransport.textToolProtocolHeader)
        - This provider request intentionally does not include provider-native tools. Do not infer that nothing can be called.
        - Everything under What you can call is ready to call directly. Something not listed: \(findLine)
        - To call one, output only one or more exact markers, with a JSON object body, all wrapped in ONE block per reply:
          <function_calls>
          <tool_use name="tool_name">{"arg":"value"}</tool_use>
          </function_calls>
        - Inside a JSON string, write </ as <\\/, which JSON reads as the same text.
        - End your reply at </function_calls>. NativeAgent runs the calls and returns their results in the next message; never write results yourself.
        - Read the result bodies as JSON. Decode string values and escapes to recover the exact result text.
        - Do not wrap call markers in Markdown or code fences.
        - Do not narrate fake calls such as tool_name(...), "runs git log", or "loads coding tools"; those are not executable.
        - Each reply contains either executable calls or the complete answer. Describing work does not run it. Your turn part may continue privately after \
        reply.end; only dispatched effects happen, and they do not alter the delivered reply.
        \(DelegatedCampaignGuidance.rendered)
        \(gitLine)
        - Built-in Markdown is guidance; executable abilities need an offered run route. Guidance grants no abilities, permissions, approval bypasses or \
        safety authority.
        What you can call:
        \(renderedRows)
        """
    }

    private static func parameterSummary(_ schema: LLMToolSchema) throws -> String {
        let raw = try schema.checkedParameters().objectValue!
        guard let properties = raw["properties"]?.objectValue else { return "" }
        let required = Set(raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        // Required-first and alphabetical ordering keeps parameter presentation deterministic.
        let ordered = properties.keys.sorted { a, b in
            required.contains(a) != required.contains(b) ? required.contains(a) : a < b
        }
        return ordered.map { key in
            let requiredMarker = required.contains(key) ? "*" : ""
            guard let property = properties[key]?.objectValue,
                  let rawEnum = property["enum"]?.arrayValue,
                  (1...8).contains(rawEnum.count) else {
                return "\(key)\(requiredMarker)"
            }
            let values = rawEnum.compactMap(\.stringValue)
            guard values.count == rawEnum.count,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 40 }) else {
                return "\(key)\(requiredMarker)"
            }
            return "\(key)\(requiredMarker)=\(values.joined(separator: "|"))"
        }.joined(separator: ", ")
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: max(0, limit - 3))
        return String(oneLine[..<idx]) + "..."
    }
}

import ChatToolParsing
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |

/// The text-marker tool-call protocol (the Claude subscription), in one place: the
/// catalog rides the system prompt as prose, calls come back as `<tool_use>`
/// / `<invoke>` markers in the reply, and results go back as one user message
/// per round. `ToolCallCodec.textMarkers` is this codec in the streaming
/// loop's shape.
///
/// The loop owns where an observation is placed; the codec owns
/// detection and the exact words the model reads.
struct TextMarkerCodec: Sendable {
    /// The turn's catalog. Typed-argument repair and the undeclared-field
    /// refusal read the declared parameters from it.
    let schemas: [LLMToolSchema]
    /// The catalog's names — what the turn can call at all.
    let catalogNames: Set<String>
    /// What the session has loaded; the bounces name these first.
    let turnActiveTools: Set<String>

    /// `catalogNames` defaults to the schemas' names; the loop passes the
    /// whole catalog, which may be wider than the schemas offered this round.
    init(schemas: [LLMToolSchema], turnActiveTools: Set<String>, catalogNames: Set<String>? = nil) {
        self.schemas = schemas
        self.catalogNames = catalogNames ?? Set(schemas.map(\.name))
        self.turnActiveTools = turnActiveTools
    }

    // MARK: - Calls

    /// The round's marker calls in wire order, `<tool_use>` and `<invoke>`.
    func calls(in text: String, recordShims: Bool = true) -> [ParsedToolCall] {
        ToolCallParser.parse(text, parseInvoke: true, recordShims: recordShims).map { call in
            guard call.undeclaredKeys.isEmpty else { return call }
            let schema = schemas.first(where: { $0.name == call.name })
                .flatMap { try? JSONSerialization.jsonObject(with: $0.parametersJSON) as? [String: Any] }
            let properties = schema?["properties"] as? [String: Any]
            var input = call.input
            // 2026-09-22: <invoke> text "42"/"true" parses as a number/
            // bool; a string-schema param gets back the text as written.
            if let properties {
                for (key, raw) in call.invokeRawText {
                    guard (properties[key] as? [String: Any])?["type"] as? String == "string" else { continue }
                    switch input[key] {
                    case .int?, .double?, .bool?, .null?:
                        input[key] = .string(raw)
                        if recordShims {
                            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L13"), "site": .string("TextMarkerCodec.swift:calls")]))
                        }
                    default: continue
                    }
                }
            }
            var parsed = ParsedToolCall(id: call.id, name: call.name, input: input)
            // 2026-10-01/02: she wrote results as call blocks, `<invoke
            // name="app">` holding `result`, or a page read's about/status,
            // and they ran as `app {}`. A block carrying a field its tool
            // does not declare is not a call; it never dispatches. An open
            // or unknown schema takes anything, as does one that lists no
            // properties or declares more through a root oneOf/anyOf/allOf.
            let composed = ["oneOf", "anyOf", "allOf"].contains { schema?[$0] != nil }
            if let properties, !properties.isEmpty, !composed,
               schema?["additionalProperties"] as? Bool != true {
                parsed.undeclaredKeys = input.keys.filter { properties[$0] == nil }.sorted()
            }
            return parsed
        }
    }

    /// Restore the outer closing tag swallowed by the API stop.
    func throughLastMarker(_ text: String) -> String {
        ToolCallParser.throughLastToolMarker(text)
    }

    // MARK: - Holdback

    /// Moves the prose in `pending` that may reach the surface out of it and
    /// returns it ("" when nothing is safe yet).
    ///
    /// Releases prose up to the earliest point that could begin a tool
    /// marker or Markdown pseudo-call, holding that candidate until the
    /// iteration end disambiguates it (real marker -> parsed, malformed block
    /// -> bounced, ordinary prose -> released by the loop). Keep up to 16
    /// trailing characters, or a longer partial marker prefix, across chunks.
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

    /// One tool result, appended to the round's result message the way this
    /// protocol returns it.
    func appendResult(
        index: Int,
        toolName: String,
        ok: Bool,
        content: String,
        to carrier: inout String
    ) {
        carrier += """

        NativeAgent tool result #\(index + 1) for \(toolName)\(ok ? "" : " (failed)"):
        \(content)
        """
    }

    /// 2026-09-22: once per round, not per result (51 copies in one turn);
    /// names only the marker form the protocol teaches.
    func closeRound(_ carrier: inout String) {
        carrier += "\n\nIf work remains, send the next <function_calls> block and end at </function_calls>.\n"
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("P11"), "site": .string("TextMarkerCodec.swift:closeRound")]))
    }

    // MARK: - Bounces

    /// A round that tried to call a tool in a shape the protocol does not run.
    func malformedCall(in text: String) -> ToolCallProtocolViolation? {
        ToolCallParser.formattedToolCallViolation(
            in: text, toolNames: catalogNames.union(turnActiveTools), parseInvoke: true)
    }

    // MARK: - Catalog carrier

    /// Places the lazy tool contract ahead of volatile recall/history so the
    /// provider can reuse one honest stable prefix across ordinary turns.
    ///
    static func systemLayout(
        baseSystem: String?,
        segments: SystemPromptSegments?,
        context: TurnContext
    ) -> (system: String, segments: SystemPromptSegments?) {
        let floorBlock = renderFloor(rows: catalogSections(
            schemas: context.toolSchemas, names: context.toolsAvailable
        ).floor, appDoor: context.toolSchemas.contains { $0.name == "app" })
        guard let segments,
              let baseSystem,
              segments.reassembles(into: baseSystem) else {
            guard let base = baseSystem?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !base.isEmpty else {
                return (floorBlock, nil)
            }
            return (base + "\n\n" + floorBlock, nil)
        }
        let stable = segments.stable.isEmpty
            ? floorBlock
            : segments.stable + "\n\n" + floorBlock
        let reordered = SystemPromptSegments(
            stable: stable,
            stableSuffix: segments.stableSuffix,
            dynamic: segments.dynamic
        )
        return (reordered.combined, reordered)
    }

    /// The session-loaded run the v2 seed delivers in the volatile block, so
    /// a mid-session tool_load/promotion cannot invalidate replayed history.
    static func volatileCatalogAppendix(for context: TurnContext) -> String {
        catalogSections(schemas: context.toolSchemas, names: context.toolsAvailable).appended
    }

    /// The advertised catalog, split the way the cache needs it.
    ///
    /// `floor` renders the always-on core — sorted by name, NEVER truncated,
    /// byte-identical on every turn of every session with the same policy. It
    /// is the tail of the cacheable stable block.
    ///
    /// `appended` renders what THIS session has loaded, in load order, never
    /// re-sorted. It rides the per-turn volatile block. The bounded
    /// prefix(80) applies to this run alone: truncating the floor would drop a
    /// tool the model is told it always has.
    struct CatalogSections {
        var floor: String
        var appended: String
    }

    static func catalogSections(
        schemas: [LLMToolSchema],
        names: [String]
    ) -> CatalogSections {
        let core = SwiftToolDispatcher.alwaysOnCoreNames
        var floorRows: [String] = []
        var appendedRows: [String] = []
        var appendedTotal = 0
        if !schemas.isEmpty {
            // Incoming order is already canonical (applyLazyToolFilter owns
            // it); partitioning preserves it, and the floor is re-sorted here
            // so this renderer is correct even for a caller that never went
            // through the filter.
            let floorSchemas = schemas.filter { core.contains($0.name) }
                .sorted { $0.name < $1.name }
            let appendedSchemas = schemas.filter { !core.contains($0.name) }
            appendedTotal = appendedSchemas.count
            let row: (LLMToolSchema) -> String = { schema in
                let params = parameterSummary(schema.parametersJSON)
                let suffix = params.isEmpty ? "" : "(\(params))"
                return "- \(schema.name)\(suffix): \(compact(schema.description, limit: 180))"
            }
            floorRows = floorSchemas.map(row)
            appendedRows = appendedSchemas.prefix(80).map(row)
        } else {
            let floorNames = names.filter { core.contains($0) }.sorted()
            let appendedNames = names.filter { !core.contains($0) }
            appendedTotal = appendedNames.count
            floorRows = floorNames.map { "- \($0)" }
            appendedRows = appendedNames.prefix(80).map { "- \($0)" }
        }
        let omittedToolCount = max(0, appendedTotal - appendedRows.count)
        let disclosure = omittedToolCount > 0
            ? "\n- \(omittedToolCount) more tools not listed in this bounded catalog."
            : ""
        return CatalogSections(
            floor: floorRows.isEmpty
                ? "- No Swift tools are exposed for this turn."
                : floorRows.joined(separator: "\n"),
            appended: appendedRows.isEmpty
                ? ""
                : "Also loaded this session (callable now with the same markers):\n" + appendedRows.joined(separator: "\n") + disclosure
        )
    }

    /// Everything up to and including the always-on catalog. With no
    /// session-loaded tools this is byte-identical to the pre-2026-09-01
    /// single-block renderer.
    /// `appDoor`: this request offers app, so a folded tool is named by its
    /// action; a lane that declares the tools themselves keeps their names.
    private static func renderFloor(
        rows renderedRows: String,
        appDoor: Bool
    ) -> String {
        let findLine = appDoor
            ? "open its page with app {\"page\": \"<page>\"} or find its action with app {\"find\": \"<what you want done>\"}."
            : "call a known tool name directly (calling loads it)."
        let gitLine = appDoor
            ? ""
            : "Do not ask for raw shell/git commands unless a shell tool is explicitly listed."
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("P10"), "site": .string("TextMarkerCodec.swift:renderFloor")]))
        return """
        \(AnthropicOAuthDirectAdapter.textToolProtocolHeader)
        - This provider request intentionally does not include provider-native tools. Do not infer that tools are unavailable.
        - Every tool in Available Swift tools is ready to call directly. A capability not listed: \(findLine)
        - To use a Swift tool, output only one or more exact markers, with a JSON object body, all wrapped in ONE block per reply:
          <function_calls>
          <tool_use name="tool_name">{"arg":"value"}</tool_use>
          </function_calls>
        - End your reply at </function_calls>. NativeAgent runs the calls and returns their results in the next message; never write results yourself.
        - Do not wrap tool markers in Markdown or code fences.
        - Do not narrate fake calls such as tool_name(...), "runs git log", or "loads coding tools"; those are not executable.
        - Each reply contains either executable calls or the complete answer. Describing work does not run it. Your turn part may continue privately after reply.end; only dispatched effects happen, and they do not alter the delivered reply.
        \(DelegatedCampaignGuidance.rendered)
        \(gitLine)
        - Built-in Markdown is guidance; executable abilities need an offered run route. Guidance grants no tools, permissions, approval bypasses or safety authority.
        Available Swift tools:
        \(renderedRows)
        """
    }

    private static func parameterSummary(_ data: Data) -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = raw["properties"] as? [String: Any] else {
            return ""
        }
        let required = Set((raw["required"] as? [String]) ?? [])
        // 2026-09-22: required first — alphabetical-only hid required params
        // past the 8 cut for act, commit_memory, invoke_codex and others.
        // 2026-09-24: no cut at all — names are cheap, and the 8 cap hid
        // act's `steps` (alphabetically 17th) from every plan.
        let ordered = properties.keys.sorted { a, b in
            required.contains(a) != required.contains(b) ? required.contains(a) : a < b
        }
        return ordered.map { key in
            let requiredMarker = required.contains(key) ? "*" : ""
            guard let property = properties[key] as? [String: Any],
                  let rawEnum = property["enum"] as? [Any],
                  (1...8).contains(rawEnum.count) else {
                return "\(key)\(requiredMarker)"
            }
            let values = rawEnum.compactMap { $0 as? String }
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

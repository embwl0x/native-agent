import ChatToolParsing
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// The text-marker tool-call protocol (the Claude subscription), in one place: the
/// catalog rides the system prompt as prose, calls come back as `<tool_use>`
/// / `<invoke>` markers in the reply, and results go back as one user message
/// per round. `ToolCallCodec.textMarkers` is this codec in the streaming
/// loop's shape.
///
/// The loop owns counts, caps and where a bounce is placed; the codec owns
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
    func calls(in text: String) -> [ParsedToolCall] {
        ToolCallParser.parse(text, parseInvoke: true).map { call in
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
                    case .int?, .double?, .bool?, .null?: input[key] = .string(raw)
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

    /// A round that called tools, cut after its last marker. Bare
    /// `<tool_use>`/`<invoke>` calls have no outer block for the API to stop
    /// on (a `</tool_use>` stop would drop parallel calls), so text after the
    /// last marker was written before any result existed — 2026-09-23
    /// claude-drive: an invented report of all five results. It is neither
    /// shown nor replayed.
    func throughLastMarker(_ text: String) -> String {
        ToolCallParser.throughLastToolMarker(text)
    }

    // MARK: - Holdback

    /// Moves the prose in `pending` that may reach the surface out of it and
    /// returns it ("" when nothing is safe yet).
    ///
    /// Final flush (`force`): EVERYTHING that remains. A real tool marker is
    /// discarded via pendingDelta.removeAll() on the tool-call path BEFORE any
    /// force flush runs, so when we reach here the iteration finished
    /// tool-free and any "<tool"-looking text is prose that must be shown.
    /// (Previously this short-circuited on "<tool" even when force==true, so a
    /// reply merely MENTIONING "<tool" never streamed — frozen bubble then an
    /// instant dump via .final. audit #6, 2026-06-14.)
    ///
    /// Otherwise: prose up to the earliest point that could begin a tool
    /// marker or Markdown pseudo-call, holding that candidate until the
    /// iteration end disambiguates it (real marker -> parsed, malformed block
    /// -> bounced, ordinary prose -> shown by the force pass). Keep a <=16-char
    /// cross-chunk tail so a candidate forming at the boundary is not split.
    static func releasableProse(holding pending: inout String, force: Bool) -> String {
        guard !pending.isEmpty else { return "" }
        if force {
            let flush = pending
            pending = ""
            return flush
        }
        let holdFrom: String.Index
        if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pending) {
            holdFrom = r.lowerBound
        } else {
            let tail = min(16, pending.count)
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
    func closeRound(_ carrier: inout String, boundaryReason: LLMToolBoundaryReason? = nil) {
        if let boundaryReason {
            let reason: String
            switch boundaryReason {
            case .repeatedBlock: reason = "a tool call repeated the immediately preceding call"
            case .repeatedAction: reason = "an action repeated an earlier action in the same reply"
            case .fabricatedResult: reason = "it contained an invented tool result after a call"
            case .postCallProse: reason = "it continued with prose after a call before receiving results"
            }
            carrier = "NativeAgent stopped this reply because \(reason). The results below account for the retained calls; calls after that boundary did not run. Use these results and make a new call only for work still needed. Do not repeat a completed action.\n" + carrier
        }
        carrier += "\n\nUse these verified results. If more work is needed, put the next calls in one <function_calls> block using <tool_use name=\"TOOL\">{\"arg\":\"value\"}</tool_use>, then end at </function_calls>. Otherwise answer directly.\n"
    }

    var protocolFailureFeedback: String {
        "No call from that reply ran. Make the needed call now: <function_calls><tool_use name=\"TOOL\">{\"arg\":\"value\"}</tool_use></function_calls>. Use the real tool name and arguments. End at </function_calls> and wait for the result."
    }

    // MARK: - Bounces

    /// A round that tried to call a tool in a shape the protocol does not run.
    func malformedCall(in text: String) -> ToolCallProtocolViolation? {
        ToolCallParser.formattedToolCallViolation(
            in: text, toolNames: catalogNames.union(turnActiveTools), parseInvoke: true)
    }

    /// A call-free round that is in-progress-shaped ("reading the README
    /// now") or names a call it never made (`**Tool: desk_read**` as the whole
    /// reply). Only a turn with tools can break that promise.
    func promisesUnfulfilledWork(_ text: String) -> Bool {
        !catalogNames.isEmpty
            && (ToolCallParser.looksLikeUnfulfilledActionPromise(text)
                || ToolCallParser.looksLikeNarratedToolInvocation(
                    text,
                    knownToolNames: catalogNames.union(turnActiveTools)
                ))
    }

    /// The tools the unfulfilled-promise bounce names as ready.
    var readyTools: String {
        let readySource = turnActiveTools.isEmpty ? catalogNames : turnActiveTools
        // A tool folded into app is ready as its app action, not by name.
        return readySource.filter { !SwiftToolDispatcher.isModelHidden($0) }.sorted().prefix(8).joined(separator: ", ")
    }

    /// The unfulfilled-promise bounce; `bounce` is 1 or 2.
    func unfulfilledPromiseFeedback(bounce: Int) -> String {
        if bounce == 1 {
            return "Your reply announced work but made no tool call. Continue in this turn: put the next calls in one <function_calls> block using <tool_use name=\"TOOL\">{\"arg\":\"value\"}</tool_use>, then end at </function_calls>, or give your complete answer. Tools ready: \(readyTools)."
        }
        return "Your reply again announced work without a tool call. This is the last continuation: put the next call in one <function_calls> block using <tool_use name=\"TOOL\">{\"arg\":\"value\"}</tool_use>, then end at </function_calls>, or give your complete answer including any concrete blocker."
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
            ? "For recent commits use app git.log, for repo state app git.status, and for diffs app git.diff. Do not ask for raw shell/git commands when those answer it."
            : "For recent commits use git_log, for repo state use git_status, and for diffs use git_diff. Do not ask for raw shell/git commands unless a shell tool is explicitly listed."
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
        - COMPLETION CONTRACT: every reply must be EITHER tool_use marker(s) OR your complete final answer. You have no background execution — work you describe but do not call never happens. A reply that only announces or narrates in-progress work ("checking now", "reading the files now", "going through it") is invalid and NativeAgent bounces it back to you. Do the work in THIS reply: emit the next tool call, or deliver the finished answer.
        \(DelegatedCampaignGuidance.rendered)
        - After NativeAgent returns a tool result, use the result to answer or emit another exact marker.
        - \(gitLine)
        - Skills provide guidance only. They never grant tools, permissions, approval bypasses, or safety authority.
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

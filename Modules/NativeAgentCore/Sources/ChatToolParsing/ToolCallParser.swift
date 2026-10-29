import Foundation
import PersistenceCore
import TurnTrace
// Blueprint: | `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |

// MARK: - Parsed tool call

package struct ParsedToolCall: Equatable {
    /// Provider-issued call id. Echoed back as `tool_result.tool_use_id`
    /// (Anthropic) or `function_call_output.call_id` (OpenAI). Empty when
    /// the parser couldn't recover one (legacy marker, bare JSON shape).
    package let id: String
    package let name: String
    package let input: [String: JSONValue]
    /// <invoke> parameters that were JSON-typed, as written, so a
    /// string-schema param given text "42" can be restored to the string.
    package var invokeRawText: [String: String] = [:]
    /// Text lane: undeclared fields or raw invoke content without parameters.
    /// Such a block is a result she wrote, not a call, and never runs.
    package var undeclaredKeys: [String] = []

    package init(
        id: String, name: String, input: [String: JSONValue],
        invokeRawText: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.invokeRawText = invokeRawText
    }
}

// MARK: - Parsing

package struct ToolCallProtocolViolation: Equatable {
    enum Kind: String, Equatable {
        case markdownToolCallBlock
        case formattedToolUseMarker
        case malformedToolUseMarker
    }

    let kind: Kind

    package var traceType: String { kind.rawValue }

    package var modelFeedback: String {
        if kind == .malformedToolUseMarker {
            return "[tool.call reason=malformed_tool_call] Broken call text; no call from this reply ran. Correct it using this conversation's call format."
        }
        return "[tool.call reason=formatted_tool_call] The call was formatted as Markdown; no call from this reply ran. Use this conversation's executable call format."
    }

}

package enum ToolCallParser {
    /// Try OpenAI shape first (whole-response JSON with tool_calls or
    /// function_call), then `<tool_use id="..." name="...">{json}</tool_use>`
    /// markers (both adapters emit this format), then bare JSON content
    /// blocks `{"type":"tool_use","id":...,"name":"...","input":{...}}`.
    /// `parseInvoke`: only the text tool lane runs Claude's `<invoke>` form.
    package static func parse(_ raw: String, parseInvoke: Bool = false, recordShims: Bool = true) -> [ParsedToolCall] {
        let parsed = try? JSONValue.parse(Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let openAI = parseOpenAI(parsed)
        let positioned = openAI == nil ? parseAnthropic(raw, parsed: parsed) : []
        let calls = openAI ?? positioned.map { $0.1 }
        guard formattedToolCallViolation(in: raw, toolNames: [], parseInvoke: parseInvoke,
                                         openAI: openAI, calls: calls) == nil else { return [] }
        if let openAI { return executableCalls(openAI) }
        // A native content block can quote invokes inside its arguments.
        let accepted = positioned.filter { parseInvoke || !$0.2 }
        if !parseInvoke, !positioned.isEmpty, accepted.isEmpty { return executableCalls(parseContentBlocks(parsed)) }
        // Only accepted calls emit receipts.
        return accepted.compactMap { positioned in
            let call = positioned.1
            guard !isIgnorableToolName(call.name) else { return nil }
            if recordShims, positioned.2, call.undeclaredKeys.isEmpty {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L12"), "site": .string("ToolCallParser.swift:parseAnthropic")]))
            }
            return call
        }
    }

    /// Restore the outer closing tag swallowed by the text-lane API stop.
    package static func throughLastToolMarker(_ raw: String) -> String {
        guard ["</tool_use>", "</invoke>", "</function_calls>"].contains(where: raw.contains) else { return raw }
        var cut = raw
        // The API stop swallows the closing tag; replay the block whole.
        if let open = cut.range(of: "<function_calls>", options: .backwards),
           cut.range(of: "</function_calls>", range: open.upperBound..<cut.endIndex) == nil {
            cut += "\n</function_calls>"
        }
        return cut
    }

    private static let toolUseMarkerRegexes = [
        #"<tool_use\s+id="[^"]*"\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        #"<tool_use\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        #"</?function_calls>"#,
        #"<invoke\s+name="[^"]+"\s*>[\s\S]*?</invoke>"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The prose without its tool-use markers, id-bearing and legacy forms both.
    package static func stripToolUseMarkers(_ raw: String) -> String {
        var s = raw
        for rx in toolUseMarkerRegexes {
            let quoted = codeRanges(in: s)
            let result = NSMutableString(string: s)
            for match in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
                where !quoted.contains(where: { NSLocationInRange(match.range.location, $0) }) {
                result.replaceCharacters(in: match.range, with: "")
            }
            s = result as String
        }
        return s
    }

    package static func executableCalls(_ calls: [ParsedToolCall]) -> [ParsedToolCall] {
        calls.filter { !isIgnorableToolName($0.name) }
    }

    package static func isIgnorableToolName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty
    }

    private static let protocolDebrisPattern = #"<parse_error>.*?(?:</parse_error>|\z)|<reasoning_effort>[^<]*(?:</reasoning_effort>|\z)|</?(?:parse|function_(?:calls|results?)|tool_results?|result)\b[^<>]*>|_\w+_placeholder"#

    private static let codeRegionRegexes = [
        #"(?ms)^[ \t]*(`{3,})[^\r\n]*\r?\n(.*?)(?:^[ \t]*\1`*[ \t]*\r?$|\z)"#,
        #"(?ms)^[ \t]*(~{3,})[^\r\n]*\r?\n(.*?)(?:^[ \t]*\1~*[ \t]*\r?$|\z)"#,
        #"(?s)(`+)(?!`)(.*?)(?<!`)\1(?!`)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func codeRanges(in raw: String) -> [NSRange] {
        codeRegionRegexes.flatMap { $0.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).map(\.range) }
    }

    /// Keep offsets while hiding quoted examples from protocol detection.
    private static func unquotedProtocolText(_ raw: String) -> String {
        let text = NSMutableString(string: raw)
        for range in codeRanges(in: raw) {
            text.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        return text as String
    }

    private static let orphanRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:</?(?:tool_use|invoke|parameter)\b|_?(?:tool_use|ool_use)\b[ \t>])"#)
    private static let invokeStartRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:<function_calls>\s*)?<invoke\b"#)
    private static let nestedMarkerRegex = try! NSRegularExpression(pattern: #"<(?:tool_use|invoke)\b"#)
    private static let formattedMarkerRegex = try! NSRegularExpression(pattern: #"(?is)(?:\*\*|__)\s*<(tool_use|invoke)\b[\s\S]*?</\1>\s*(?:\*\*|__)"#)
    private static let headerRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:\d+[ \t]*)?(?:\*\*|__)?[ \t]*Tool[ \t]+Call[ \t]*(?::[ \t]*[A-Za-z0-9_.:-]*)?[ \t]*(?:\*\*|__)?[ \t]*$"#)
    private static let fencedJSONRegex = try! NSRegularExpression(pattern: #"(?is)(?:```|~~~)[ \t]*(?:json)?[ \t]*\r?\n[ \t]*\{[\s\S]*?(?:```|~~~)"#)
    private static let markerRegex = try! NSRegularExpression(pattern: #"<tool_use\s+(?:id="([^"]*)"\s+)?name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#)
    private static let positionedMarkerRegex = try! NSRegularExpression(pattern: "(?=" + markerRegex.pattern + ")")
    private static let invokeRegex = try! NSRegularExpression(pattern: #"<invoke\s+name="([^"]+)"\s*>([\s\S]*?)</invoke>"#)
    private static let parameterRegex = try! NSRegularExpression(pattern: #"<parameter\s+name="([^"]+)"\s*>([\s\S]*?)</parameter>"#)
    // Overlapping matches let a complete inner call survive an unfinished outer call.
    private static let repairRegionRegex = try! NSRegularExpression(pattern: #"(?=<(?<tag>tool_use|invoke|parameter)\s+(?:id="(?<id>[^"]*)"\s+)?name="(?<name>[^"]+)"\s*>(?<body>(?:\s*"# + parameterRegex.pattern + #"\s*)+|[\s\S]*?)(?:</\k<tag>>|(?=\s*</[\w.:-]+>)|\z))"#)

    /// Control debris is not prose, even when the provider ends inside it.
    /// Keep fenced and inline code and complete calls intact, including their arguments.
    package static func stripProtocolDebris(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: #"(?is)(```.*?```|~~~.*?~~~|(?<!`)(`+)(?!`).*?(?<!`)\2(?!`)|<tool_use\b[^<>]*>.*?</tool_use>|<invoke\b[^<>]*>.*?</invoke>)|(?:"# + protocolDebrisPattern + ")",
            with: "$1", options: .regularExpression)
        // Debris stripping is protocol transport and carries no receipt (L16 stays uninstrumented: the envelope is expected, so a stamp could not tell debris from protocol).
        return stripped
    }

    /// Broken or formatted executable calls get a format nudge; quoted code is prose.
    /// The shared loop gives one format nudge before settling incomplete.
    package static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String> = [], parseInvoke: Bool = false
    ) -> ToolCallProtocolViolation? {
        let parsed = try? JSONValue.parse(Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let openAI = parseOpenAI(parsed)
        return formattedToolCallViolation(in: raw, toolNames: toolNames, parseInvoke: parseInvoke,
                                          openAI: openAI, calls: openAI ?? parseAnthropic(raw, parsed: parsed).map { $0.1 })
    }

    private static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String>, parseInvoke: Bool,
        openAI: [ParsedToolCall]?, calls: [ParsedToolCall]
    ) -> ToolCallProtocolViolation? {
        let unquoted = unquotedProtocolText(raw)
        // Remove complete calls before looking for orphan tags or placeholders.
        // Their arguments may legitimately contain these strings.
        let remainder = stripToolUseMarkers(unquoted)
        if regexMatches(orphanRegex, in: remainder)
            || (!unquoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && stripProtocolDebris(unquoted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (!parseInvoke && regexMatches(invokeStartRegex, in: unquoted))
            || (openAI != nil && calls.isEmpty)
            || (!calls.isEmpty && executableCalls(calls).isEmpty) {
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }

        if regexMatches(formattedMarkerRegex, in: unquoted) {
            return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
        }

        // Pin the real failure shape observed on Telegram:
        //   **Tool Call: codex_message**
        //   ```json
        //   { ... }
        //   ```
        // Requiring both an exact header line and a following fenced JSON
        // object avoids bouncing ordinary prose that merely discusses calls.
        if regexMatches(headerRegex, in: unquoted), regexMatches(fencedJSONRegex, in: raw) {
            return ToolCallProtocolViolation(kind: .markdownToolCallBlock)
        }

        // Known tool markers require a JSON object body; quoted syntax is prose.
        let ns = raw as NSString
        let quoted = codeRanges(in: raw)
        for m in markerRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            guard toolNames.contains(ns.substring(with: m.range(at: 2))) else { continue }
            let body = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if markerObject(body) != nil { continue }
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }
        return nil
    }

    /// Only the rejected text lane calls this; canonical parsing stays unchanged.
    package static func repairMalformedRegion(in raw: String, toolNames: Set<String>) -> String? {
        guard let start = earliestPotentialProtocolMarker(in: raw)?.lowerBound else { return nil }
        let ns = raw as NSString
        // Keep the full reply's quotation context, including fences before the marker.
        let quoted = codeRanges(in: raw)
        var replacements: [String] = []
        for region in repairRegionRegex.matches(in: raw, range: NSRange(start..., in: raw)) {
            guard !quoted.contains(where: { NSLocationInRange(region.range.location, $0) }) else { continue }
            let name = ns.substring(with: region.range(withName: "name"))
            guard toolNames.contains(name), !isIgnorableToolName(name) else { continue }
            let body = ns.substring(with: region.range(withName: "body")).trimmingCharacters(in: .whitespacesAndNewlines)
            if let input = markerObject(body),
               let json = try? JSONValue.object(input).serialize(pretty: false) {
                let id = region.range(withName: "id").location == NSNotFound
                    ? "" : " id=\"\(ns.substring(with: region.range(withName: "id")))\""
                replacements.append("<tool_use\(id) name=\"\(name)\">\(json)</tool_use>")
            } else {
                let bns = body as NSString
                let parameters = parameterRegex.matches(in: body, range: NSRange(location: 0, length: bns.length))
                let keys = parameters.map { bns.substring(with: $0.range(at: 1)) }
                guard !parameters.isEmpty, Set(keys).count == keys.count,
                      !regexMatches(nestedMarkerRegex, in: body),
                      parameterRegex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: bns.length),
                        withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                replacements.append("<invoke name=\"\(name)\">\(body)</invoke>")
            }
        }
        guard replacements.count == 1, let replacement = replacements.first else { return nil }
        let repaired = String(raw[..<start]) + replacement
        guard formattedToolCallViolation(in: repaired, toolNames: toolNames, parseInvoke: true) == nil else { return nil }
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L10"), "site": .string("ToolCallParser.swift:repairMalformedRegion")]))
        return repaired
    }

    package static let protocolMarkerStarts = [
        "<tool", "tool_use", "ool_use",
        "**tool call", "__tool call", "tool call:",
        "<function_calls", "</function_calls", "<invoke", "<parameter", "</tool_use", "</invoke", "</parameter",
        "_tool_use", "_fn_placeholder", "_call_placeholder", "<reasoning_effort", "<parse", "</parse",
        "<function_result", "</function_result", "</tool_result", "<result", "</result",
    ]

    /// Hold potential call text until the complete round can be checked.
    package static func earliestPotentialProtocolMarker(in raw: String) -> Range<String.Index>? {
        var candidates = protocolMarkerStarts.compactMap { needle in
            raw.range(of: needle, options: [.caseInsensitive])
        }
        if let placeholder = raw.range(of: #"_\w+_placeholder"#, options: .regularExpression) {
            candidates.append(placeholder)
        }
        if let tool = raw.range(of: "<tool", options: [.caseInsensitive]) {
            let prefix = raw[..<tool.lowerBound]
            // Keep a surrounding Markdown wrapper until the round can distinguish an example.
            for wrapper in ["```", "~~~", "**", "__", "`"] {
                if let start = prefix.range(of: wrapper, options: .backwards) {
                    candidates.append(start)
                }
            }
        }
        return candidates.min { $0.lowerBound < $1.lowerBound }
    }

    /// Visible prose preceding the earliest possible protocol marker, unchanged if absent.
    package static func visiblePrefix(in raw: String) -> String {
        let unquoted = unquotedProtocolText(raw)
        if let candidate = earliestPotentialProtocolMarker(in: unquoted),
           let marker = Range(NSRange(candidate, in: unquoted), in: raw) {
            return stripProtocolDebris(String(raw[..<marker.lowerBound]))
        }
        return stripProtocolDebris(raw)
    }

    private static func regexMatches(_ regex: NSRegularExpression, in raw: String) -> Bool {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.firstMatch(in: raw, range: range) != nil
    }

    // OpenAI: response body is a JSON object containing either
    //   "tool_calls": [{"id":..., "function":{"name":..., "arguments":"<json-string>"}}]
    // or
    //   "function_call": {"name":..., "arguments":"<json-string>"}
    private static func parseOpenAI(_ parsed: JSONValue?) -> [ParsedToolCall]? {
        guard case .object(let obj)? = parsed else { return nil }
        if case .array(let arr) = obj["tool_calls"] ?? .null {
            var calls: [ParsedToolCall] = []
            for item in arr {
                guard case .object(let tc) = item else { continue }
                guard case .object(let fn) = tc["function"] ?? .null else { continue }
                guard case .string(let name) = fn["name"] ?? .null else { continue }
                let id: String = {
                    if case .string(let s) = tc["id"] ?? .null { return s }
                    return ""
                }()
                calls.append(argumentsCall(id: id, name: name, fn["arguments"] ?? .null))
            }
            return calls
        }
        if case .object(let fn) = obj["function_call"] ?? .null,
           case .string(let name) = fn["name"] ?? .null {
            let id: String = {
                if case .string(let s) = fn["call_id"] ?? .null { return s }
                return ""
            }()
            return [argumentsCall(id: id, name: name, fn["arguments"] ?? .null)]
        }
        return nil
    }

    /// A call's arguments as one object. Absent or empty arguments are none;
    /// anything else that is not one JSON object is a body that never runs
    /// (`undeclaredKeys` says why), never an empty call.
    static func argumentsCall(id: String, name: String, _ arguments: JSONValue) -> ParsedToolCall {
        let input: [String: JSONValue]?
        switch arguments {
        case .null: input = [:]
        case .object(let o): input = o
        case .string(let s) where s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: input = [:]
        case .string(let s):
            if case .object(let o)? = try? JSONValue.parse(Data(s.utf8)) { input = o } else { input = nil }
        default: input = nil
        }
        var call = ParsedToolCall(id: id, name: name, input: input ?? [:])
        if input == nil { call.undeclaredKeys = ["arguments that are not one JSON object"] }
        return call
    }

    /// Read the marker body as the declared JSON object.
    static func markerObject(_ body: String) -> [String: JSONValue]? {
        guard case .object(let object)? = try? JSONValue.parse(Data(body.utf8)) else { return nil }
        return object
    }

    private static func parseAnthropic(_ raw: String, parsed: JSONValue?) -> [(Int, ParsedToolCall, Bool)] {
        var positionedCalls: [(Int, ParsedToolCall, Bool)] = []
        let ns = raw as NSString
        let quoted = codeRanges(in: raw)
        // Each spelling consumes its own span, including rejected swallowed markers.
        var consumed: [Bool: Int] = [:]
        for m in positionedMarkerRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let hasID = m.range(at: 1).location != NSNotFound
            guard m.range.location >= consumed[hasID, default: 0] else { continue }
            consumed[hasID] = NSMaxRange(m.range(at: 3)) + "</tool_use>".utf16.count
            guard !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) else { continue }
            let id = hasID ? ns.substring(with: m.range(at: 1)) : ""
            let name = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            // An unclosed ID-less marker cannot swallow a later call.
            if !hasID, body.contains("<tool_use") { continue }
            positionedCalls.append((m.range.location, argumentsCall(id: id, name: name, .string(body)), false))
        }
        for m in invokeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let bns = body as NSString
            var input: [String: JSONValue] = [:]
            var rawText: [String: String] = [:]
            for p in parameterRegex.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let key = bns.substring(with: p.range(at: 1))
                let value = bns.substring(with: p.range(at: 2))
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = trimmed.data(using: .utf8), let parsed = try? JSONValue.parse(d),
                   trimmed.first.map({ "{[0123456789-tfn".contains($0) }) == true {
                    input[key] = parsed
                    rawText[key] = value
                } else { input[key] = .string(value) }
            }
            var call = ParsedToolCall(id: "", name: name, input: input, invokeRawText: rawText)
            if input.isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                call.undeclaredKeys = ["raw <invoke> body without <parameter> elements"]
            }
            positionedCalls.append((m.range.location, call, true))
        }
        if !positionedCalls.isEmpty { return positionedCalls.sorted { $0.0 < $1.0 } }
        return parseContentBlocks(parsed).enumerated().map { ($0.offset, $0.element, false) }
    }

    private static func parseContentBlocks(_ parsed: JSONValue?) -> [ParsedToolCall] {
        guard let parsed else { return [] }
        let blocks = if case .array(let blocks) = parsed { blocks } else { [parsed] }
        return blocks.compactMap { block in
            guard case .object(let fields) = block, fields["type"] == .string("tool_use"),
                  case .string(let name)? = fields["name"] else { return nil }
            let id = if case .string(let id)? = fields["id"] { id } else { "" }
            return argumentsCall(id: id, name: name, fields["input"] ?? .null)
        }
    }
}

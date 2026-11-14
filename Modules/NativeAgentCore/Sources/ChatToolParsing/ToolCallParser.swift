import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace
// Blueprint: | `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |

// MARK: - Parsed tool call

package struct ParsedToolCall: Equatable {
    /// Provider-issued call id. Echoed back as `tool_result.tool_use_id` (Anthropic) or `function_call_output.call_id` (OpenAI). Empty when the text-marker
    /// protocol supplied none.
    package let id: String
    package let name: String
    package let input: [String: JSONValue]
    /// <invoke> parameters that were JSON-typed, as written, so a string-schema param given text "42" can be restored to the string.
    package var invokeRawText: [String: String] = [:]
    /// Text lane: undeclared fields or raw invoke content without parameters. Such a block is a result the agent wrote, not a call, and never runs.
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
            return "Broken call text; no call from this reply ran. Correct it using this conversation's call format. "
                + "A literal </ inside a JSON string ends the call early: write it as <\\/."
        }
        return """
            The call was formatted as Markdown; no call from this reply ran. Use this conversation's executable call format.
            """
    }

}

package enum ToolCallParser {
    /// Native calls belong to their transport decoder; only the text protocol parses invoke markup.
    package static func parse(_ raw: String, parseInvoke: Bool = false, recordShims: Bool = true) -> [ParsedToolCall] {
        let positioned = parseAnthropic(raw)
        guard formattedToolCallViolation(in: raw, toolNames: Set(positioned.map { $0.1.name }), parseInvoke: parseInvoke,
                                         calls: positioned.map { $0.1 }) == nil else { return [] }
        let accepted = positioned.filter { parseInvoke || !$0.2 }
        // Only accepted calls emit receipts.
        return accepted.compactMap { positioned in
            let call = positioned.1
            guard !isIgnorableToolName(call.name) else { return nil }
            if recordShims, positioned.2, call.undeclaredKeys.isEmpty {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L12"), "site": .string(
                    "ToolCallParser.swift:parseAnthropic")]), turn: nil)
            }
            return call
        }
    }

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

    // The model's trained <invoke> tag around a JSON object is the same call, closed by either tag; any other <invoke> body is the <parameter> form.
    private static let invokeMarker = #"<invoke(?=[^>]*>\s*\{)\s+name="([^"]+)"\s*>([\s\S]*?)(</(?:tool_use|invoke)>)"#

    private static let toolUseMarkerRegexes = [
        #"<tool_use\s+id="[^"]*"\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        #"<tool_use\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        invokeMarker,
        #"</?function_calls>"#,
        #"<invoke\s+name="[^"]+"\s*>[\s\S]*?</invoke>"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    package static func stripToolUseMarkers(_ raw: String) -> String {
        var s = raw
        for rx in toolUseMarkerRegexes {
            let quoted = codeRanges(in: s)
            var spans: [NSRange] = []
            for match in rx.matches(in: s, range: NSRange(s.startIndex..., in: s))
                where !quoted.contains(where: { NSLocationInRange(match.range.location, $0) }) {
                guard match.range.location >= spans.last.map({ NSMaxRange($0) }) ?? 0 else { continue }
                // A call goes through its JSON's end, so a closing marker inside one of its strings goes with it.
                let end = max(NSMaxRange(match.range), callEnd(at: match.range.location, in: s) ?? 0)
                spans.append(NSRange(location: match.range.location, length: end - match.range.location))
            }
            let result = NSMutableString(string: s)
            for span in spans.reversed() {
                result.replaceCharacters(in: span, with: "")
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
    private static let formattedMarkerRegex = try! NSRegularExpression(
        pattern: #"(?is)(?:\*\*|__)\s*<(?:tool_use|invoke)\b[\s\S]*?</(?:tool_use|invoke)>\s*(?:\*\*|__)"#)
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"(?im)^[ \t]*(?:\d+[ \t]*)?(?:\*\*|__)?[ \t]*Tool[ \t]+Call[ \t]*(?::[ \t]*[A-Za-z0-9_.:-]*)?[ \t]*(?:\*\*|__)?[ \t]*$"#)
    private static let fencedJSONRegex = try! NSRegularExpression(pattern: #"(?is)(?:```|~~~)[ \t]*(?:json)?[ \t]*\r?\n[ \t]*\{[\s\S]*?(?:```|~~~)"#)
    private static let markerRegex = try! NSRegularExpression(
        pattern: #"<tool_use\s+(?:id="([^"]*)"\s+)?name="([^"]+)"\s*>([\s\S]*?)(</tool_use>)|"# + invokeMarker)
    private static let positionedMarkerRegex = try! NSRegularExpression(pattern: "(?=" + markerRegex.pattern + ")")
    private static let invokeRegex = try! NSRegularExpression(pattern: #"<invoke\s+name="([^"]+)"\s*>(?!\s*\{)([\s\S]*?)</invoke>"#)
    /// A call marker as written: its name, its body and where the call ends.
    private struct Marker {
        let name: String
        let body: String
        let bodyRange: NSRange
        let end: Int
    }

    /// A marker match's name, body and end, in whichever spelling it was written. The body is read as JSON: one JSON object runs to its own
    /// end and the closing marker written right after it, so a closing marker inside one of its strings is content. Any other body ends where
    /// the pattern ends it, at the first closing marker.
    private static func marker(_ m: NSTextCheckingResult, in ns: NSString) -> Marker {
        let g = m.range(at: 2).location != NSNotFound ? 2 : 5
        let name = ns.substring(with: m.range(at: g))
        let written = m.range(at: g + 1)
        let end = NSMaxRange(m.range(at: g + 2))
        let closers = g == 2 ? ["</tool_use>"] : ["</tool_use>", "</invoke>"]
        if case .closed(_, let closer?)? = JSONByteScanner.objectRead(ns.substring(from: written.location), closers: closers),
           written.location + closer.upperBound > end {
            let framed = NSRange(location: written.location, length: closer.lowerBound)
            let body = ns.substring(with: framed)
            if markerObject(body.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                return Marker(name: name, body: body, bodyRange: framed, end: written.location + closer.upperBound)
            }
        }
        return Marker(name: name, body: ns.substring(with: written), bodyRange: written, end: end)
    }

    /// Where the call marker that opens at `location` ends, read through its JSON; nil when no call marker opens there.
    private static func callEnd(at location: Int, in text: String) -> Int? {
        let ns = text as NSString
        return markerRegex.firstMatch(in: text, options: .anchored, range: NSRange(location: location, length: ns.length - location))
            .map { marker($0, in: ns).end }
    }

    /// Each call marker in order, read through its JSON; a match that starts inside an earlier call is that call's text.
    private static func framedMarkers(in text: String) -> [(match: NSTextCheckingResult, call: Marker)] {
        let ns = text as NSString
        var found: [(match: NSTextCheckingResult, call: Marker)] = []
        for m in markerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where m.range.location >= (found.last?.call.end ?? 0) {
            found.append((m, marker(m, in: ns)))
        }
        return found
    }

    /// Offsets kept, each call's JSON arguments blanked: what their strings say is content, never Markdown around a marker.
    private static func blankingArguments(_ text: String) -> String {
        let result = NSMutableString(string: text)
        // Only arguments holding a "<" can hold marker text.
        for (_, call) in framedMarkers(in: text) where call.body.contains("<")
            && markerObject(call.body.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            result.replaceCharacters(in: call.bodyRange, with: String(repeating: " ", count: call.bodyRange.length))
        }
        return result as String
    }
    private static let parameterRegex = try! NSRegularExpression(pattern: #"<parameter\s+name="([^"]+)"\s*>([\s\S]*?)</parameter>"#)

    /// Control debris is not prose, even when the provider ends inside it. Keep fenced and inline code and complete calls intact, including their
    /// arguments.
    package static func stripProtocolDebris(_ raw: String) -> String {
        let ns = raw as NSString
        let framed = framedMarkers(in: raw).filter { $0.call.end > NSMaxRange($0.match.range) }
        guard !framed.isEmpty else { return strippingDebris(raw) }
        // A call whose JSON runs past the first closing marker (one written inside a string) is kept whole; the pattern reads the rest.
        let quoted = codeRanges(in: raw)
        var kept = ""
        var from = 0
        for (m, call) in framed where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            kept += strippingDebris(ns.substring(with: NSRange(location: from, length: m.range.location - from)))
                + ns.substring(with: NSRange(location: m.range.location, length: call.end - m.range.location))
            from = call.end
        }
        return kept + strippingDebris(ns.substring(from: from))
    }

    private static func strippingDebris(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: #"(?is)(```.*?```|~~~.*?~~~|(?<!`)(`+)(?!`).*?(?<!`)\2(?!`)|<tool_use\b[^<>]*>.*?</tool_use>"#
                + #"|<invoke\b[^<>]*>\s*\{.*?</(?:tool_use|invoke)>|<invoke\b[^<>]*>.*?</invoke>)|(?:"# + protocolDebrisPattern + ")",
            with: "$1", options: .regularExpression)
        // Expected protocol debris carries no receipt because a stamp cannot distinguish it from valid protocol.
        return stripped
    }

    /// Broken or formatted executable calls get a format nudge; quoted code is prose. The shared loop gives one format nudge before settling incomplete.
    package static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String> = [], parseInvoke: Bool = false
    ) -> ToolCallProtocolViolation? {
        return formattedToolCallViolation(in: raw, toolNames: toolNames, parseInvoke: parseInvoke,
                                          calls: parseAnthropic(raw).map { $0.1 })
    }

    private static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String>, parseInvoke: Bool,
        calls: [ParsedToolCall]
    ) -> ToolCallProtocolViolation? {
        let unquoted = unquotedProtocolText(raw)
        // Remove complete calls before looking for orphan tags or placeholders. Their arguments may legitimately contain these strings.
        let remainder = stripToolUseMarkers(unquoted)
        if regexMatches(orphanRegex, in: remainder)
            || (!unquoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && stripProtocolDebris(unquoted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (!parseInvoke && regexMatches(invokeStartRegex, in: unquoted))
            || (!calls.isEmpty && executableCalls(calls).isEmpty) {
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }

        if regexMatches(formattedMarkerRegex, in: blankingArguments(unquoted)) {
            return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
        }

        // Require an exact call header followed by a fenced JSON object to avoid bouncing ordinary discussion of calls.
        if regexMatches(headerRegex, in: unquoted), regexMatches(fencedJSONRegex, in: raw) {
            return ToolCallProtocolViolation(kind: .markdownToolCallBlock)
        }

        // Known tool markers require a JSON object body; quoted syntax is prose.
        let ns = raw as NSString
        let quoted = codeRanges(in: raw)
        for m in invokeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            if invokeParameters(in: ns.substring(with: m.range(at: 2))) == nil {
                return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
            }
        }
        for (m, call) in framedMarkers(in: raw) where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            // Only the text protocol runs invoke markup; on any other wire it is a call that will not run.
            if !parseInvoke, m.range(at: 5).location != NSNotFound { return ToolCallProtocolViolation(kind: .malformedToolUseMarker) }
            guard toolNames.contains(call.name) else { continue }
            if markerObject(call.body.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { continue }
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }
        return nil
    }

    package static let protocolMarkerStarts = [
        "<tool", "tool_use", "ool_use",
        "**tool call", "__tool call", "tool call:",
        "<function_calls", "</function_calls", "<invoke", "<parameter", "</tool_use", "</invoke", "</parameter",
        "_tool_use", "_fn_placeholder", "_call_placeholder", "<reasoning_effort", "<parse", "</parse",
        "<function_result", "</function_result", "</tool_result", "<result", "</result",
    ]

    private static let openMarkerRegex = try! NSRegularExpression(pattern: #"<(?:tool_use|invoke)\b[^>]*\bname="([^"]+)"[^>]*>"#)

    /// A call still being written in held text: the last marker that opened and has not closed, with its name and the input written so far.
    /// Movement only, never a call to run.
    package static func callBeingWritten(in held: String) -> (name: String, input: Substring)? {
        let ns = held as NSString
        guard let open = openMarkerRegex.matches(in: held, range: NSRange(location: 0, length: ns.length)).last,
              let name = Range(open.range(at: 1), in: held), let body = Range(open.range, in: held) else { return nil }
        let input = held[body.upperBound...]
        // The input is read as JSON: while its object is still open, a closing marker inside one of its strings is content.
        if JSONByteScanner.objectRead(input, closers: []) == .open { return (String(held[name]), input) }
        guard !input.contains("</tool_use>"), !input.contains("</invoke>") else { return nil }
        return (String(held[name]), input)
    }

    /// Where the reply ends when its call stands outside a block. On the text wire a `<function_calls>` block is ended by its closing mark;
    /// a call written with no block around it has no mark coming, so it is a block of one and the reply ends where the call does. Nil while
    /// no complete call opens its own line outside a block. `appended` is how many characters just arrived: a call can only have completed
    /// inside them, so text read before is not read again. The end is a UTF-16 offset, as marker text is measured.
    package static func bareCallEnd(in text: String, appended: Int) -> Int? {
        let tail = text.suffix(appended + 12)
        guard tail.contains("</tool_use>") || tail.contains("</invoke>") else { return nil }
        guard let first = framedCalls(text).first else { return nil }
        let ns = text as NSString
        guard !(unquotedProtocolText(text) as NSString).substring(to: first.0).contains("<function_calls") else { return nil }
        // A call opens its own line. One written after other words on a line may be an example whose closing backtick has not arrived.
        let line = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: first.0))
        let lineStart = line.location == NSNotFound ? 0 : NSMaxRange(line)
        guard ns.substring(with: NSRange(location: lineStart, length: first.0 - lineStart)).allSatisfy(\.isWhitespace) else { return nil }
        let opened = ns.range(of: ">", range: NSRange(location: first.0, length: first.3 - first.0))
        guard opened.location != NSNotFound else { return nil }
        // A body that is one JSON object ends at the closing marker written right after the object. Until that marker is there the call
        // is still being written, and a closing marker read so far is inside one of its strings.
        let closers = ns.substring(from: first.0).hasPrefix("<tool_use") ? ["</tool_use>"] : ["</tool_use>", "</invoke>"]
        switch JSONByteScanner.objectRead(ns.substring(from: NSMaxRange(opened)), closers: closers) {
        case .open?, .closed(_, nil)?: return nil
        case .closed(_, let closer?)?: return NSMaxRange(opened) + closer.upperBound
        case nil: return first.3
        }
    }

    /// Held text that opens at a marker: nothing before it is left to release.
    package static func opensAtProtocolMarker(_ held: String) -> Bool {
        protocolMarkerStarts.contains { held.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
    }

    /// Hold potential call text until the complete round can distinguish calls from examples.
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

    /// A call's arguments as one object. Absent or empty arguments are none; anything else that is not one JSON object is a body that never runs
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

    static func markerObject(_ body: String) -> [String: JSONValue]? {
        guard case .object(let object)? = try? JSONValue.parse(Data(body.utf8)) else { return nil }
        return object
    }

    /// Validate the entire invoke body before constructing an argument map. Empty/whitespace bodies are the valid zero-argument call.
    private static func invokeParameters(in body: String) -> [NSTextCheckingResult]? {
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        let parameters = parameterRegex.matches(in: body, range: range)
        let keys = parameters.map { ns.substring(with: $0.range(at: 1)) }
        guard Set(keys).count == keys.count,
              parameterRegex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parameters
    }

    private static func parseAnthropic(_ raw: String) -> [(Int, ParsedToolCall, Bool)] {
        framedCalls(raw).map { ($0.0, $0.1, $0.2) }
    }

    /// Each call the text holds, in order: where it opens, the call, whether it is written as invoke parameters, and where it ends.
    private static func framedCalls(_ raw: String) -> [(Int, ParsedToolCall, Bool, Int)] {
        var positionedCalls: [(Int, ParsedToolCall, Bool)] = []
        let ns = raw as NSString
        let quoted = codeRanges(in: raw)
        // Each spelling consumes its own span, including rejected swallowed markers.
        var consumed: [Bool: Int] = [:]
        var ends: [Int: Int] = [:]
        for m in positionedMarkerRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let hasID = m.range(at: 1).location != NSNotFound
            guard m.range.location >= consumed[hasID, default: 0] else { continue }
            let written = marker(m, in: ns)
            let (name, body, end) = (written.name, written.body, written.end)
            consumed[hasID] = end
            guard !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) else { continue }
            let id = hasID ? ns.substring(with: m.range(at: 1)) : ""
            // An unclosed ID-less marker cannot swallow a later call; one JSON object swallowed none, whatever its strings say.
            if !hasID, body.contains("<tool_use"), markerObject(body.trimmingCharacters(in: .whitespacesAndNewlines)) == nil { continue }
            positionedCalls.append((m.range.location, argumentsCall(id: id, name: name, .string(body)), false))
            ends[m.range.location] = end
        }
        for m in invokeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            where !quoted.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let bns = body as NSString
            guard let parameters = invokeParameters(in: body) else { continue }
            var input: [String: JSONValue] = [:]
            var rawText: [String: String] = [:]
            for p in parameters {
                let key = bns.substring(with: p.range(at: 1))
                let value = bns.substring(with: p.range(at: 2))
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = trimmed.data(using: .utf8), let parsed = try? JSONValue.parse(d),
                   trimmed.first.map({ "{[0123456789-tfn".contains($0) }) == true {
                    input[key] = parsed
                    rawText[key] = value
                } else { input[key] = .string(value) }
            }
            let call = ParsedToolCall(id: "", name: name, input: input, invokeRawText: rawText)
            positionedCalls.append((m.range.location, call, true))
            ends[m.range.location] = NSMaxRange(m.range)
        }
        // A call written inside another call's body is that call's text, never a second call.
        var owned = 0
        return positionedCalls.sorted { $0.0 < $1.0 }.compactMap { call in
            guard call.0 >= owned else { return nil }
            owned = ends[call.0] ?? owned
            return (call.0, call.1, call.2, owned)
        }
    }
}

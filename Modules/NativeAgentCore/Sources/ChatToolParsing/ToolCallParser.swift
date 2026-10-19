import Foundation
import PersistenceCore

// MARK: - Parsed tool call

package struct ParsedToolCall: Equatable {
    /// Provider-issued call id. Echoed back as `tool_result.tool_use_id`
    /// (Anthropic) or `function_call_output.call_id` (OpenAI). Empty when
    /// the parser couldn't recover one (legacy marker, bare JSON shape).
    package let id: String
    package let name: String
    package let input: [String: JSONValue]
    /// 2026-09-22: <invoke> parameters that were JSON-typed, as written, so a
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
            return "Your reply contained broken tool-call text. No call from it ran. Use this conversation's tool-call format to make the needed call now."
        }
        return "Your reply formatted a tool call as Markdown. No call from it ran. Use this conversation's tool-call format to make the needed call now."
    }

}

package enum ToolCallParser {
    /// Try OpenAI shape first (whole-response JSON with tool_calls or
    /// function_call), then `<tool_use id="..." name="...">{json}</tool_use>`
    /// markers (both adapters emit this format), then bare JSON content
    /// blocks `{"type":"tool_use","id":...,"name":"...","input":{...}}`.
    /// `parseInvoke`: only the text tool lane runs Claude's `<invoke>` form.
    package static func parse(_ raw: String, parseInvoke: Bool = false) -> [ParsedToolCall] {
        let openAI = parseOpenAI(raw)
        let calls = openAI ?? parseAnthropic(raw, parseInvoke: true)
        guard formattedToolCallViolation(in: raw, toolNames: [], parseInvoke: parseInvoke,
                                         openAI: openAI, calls: calls) == nil else { return [] }
        // Validation recognizes inline invokes even when this lane cannot execute them.
        if openAI == nil, !parseInvoke, regexMatches(invokeRegex, in: raw) {
            return executableCalls(parseAnthropic(raw))
        }
        return executableCalls(calls)
    }

    /// `raw` up to the end of its last tool marker (unchanged when it has none).
    package static func throughLastToolMarker(_ raw: String) -> String {
        let ends = ["</tool_use>", "</invoke>", "</function_calls>"].compactMap {
            raw.range(of: $0, options: .backwards)?.upperBound
        }
        guard let end = ends.max() else { return raw }
        let cut = String(raw[..<end])
        // The API stop swallows the closing tag; replay the block whole.
        if let open = cut.range(of: "<function_calls>", options: .backwards),
           cut.range(of: "</function_calls>", range: open.upperBound..<cut.endIndex) == nil {
            return cut + "\n</function_calls>"
        }
        return cut
    }

    /// Wave 2 #7: work promised for a LATER turn, which MY QUEUE keeps (the
    /// in-turn shapes above still bounce first). Conservative
    /// on purpose: a sentence counts only with BOTH a first-person commitment
    /// (I'll / I will / I'm going to; not negated, not "I'll be") AND an
    /// explicit cross-turn marker. A question, an offer or a conditional
    /// ("if", "would", "could", "might", "want me to", "should I", "unless")
    /// never counts, nor text in quotes, code fences or block quotes. Each hit
    /// is the sentence as she wrote it and the condition its marker names:
    /// after_card, when_user_messages, own_turn or next_turn. Three at most.
    package static func crossTurnDeferrals(_ raw: String) -> [(sentence: String, when: String)] {
        var prose = raw.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "\n", options: .regularExpression)
        prose = prose.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: "\n")
        var found: [(sentence: String, when: String)] = []
        for piece in prose.split(whereSeparator: { ".!?;\n".contains($0) }) where found.count < 3 {
            let sentence = piece.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•_ "))
            guard (12...280).contains(sentence.count),
                  prose[piece.endIndex...].first != "?" else { continue }
            let text = sentence.lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
                .replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: " ", options: .regularExpression)
            func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
            guard has(#"\b(i'll|i\s+will|i'm\s+going\s+to|i\s+am\s+going\s+to)\s+(?!(not|never|be)\b)[a-z]"#),
                  !has(#"\b(if|would|could|might|unless|whether|want\s+me|should\s+i)\b"#) else { continue }
            let when: String
            if has(#"\b(once|after|when)\s+(you|user|he)\s+(approve|approves|ok|oks|okay|okays|sign\s+off|signs\s+off)\b"#)
                || has(#"\b(once|after|when)\s+(the\s+|that\s+|this\s+)?(card|approval)\b"#)
                || has(#"\bonce\s+((it|that|this)('s|\s+is)\s+)?approved\b"#) {
                when = "after_card"
            } else if has(#"\b(once|after|when)\s+(you|user|he)\s+(reply|replies|respond|responds|write|writes|message|messages|text|texts|get\s+back|gets\s+back|come\s+back|comes\s+back|wake|wakes)\b"#)
                || has(#"\b(once|after|when)\s+(you're|you\s+are|user's|user\s+is|he's|he\s+is)\s+back\b"#) {
                when = "when_user_messages"
            } else if has(#"\b(on|in|during)\s+my\s+own\s+(turn|time)\b"#) || has(#"\bwhen\s+i\s+(next\s+)?wake\b"#) {
                when = "own_turn"
            } else if has(#"\b(next|following)\s+turn\b"#) || has(#"\bin\s+my\s+next\s+(reply|message)\b"#) {
                when = "next_turn"
            } else { continue }
            found.append((sentence, when))
        }
        return found
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
            s = rx.stringByReplacingMatches(
                in: s, options: [],
                range: NSRange(s.startIndex..., in: s), withTemplate: ""
            )
        }
        return s
    }

    package static func executableCalls(_ calls: [ParsedToolCall]) -> [ParsedToolCall] {
        calls.filter { !isIgnorableToolName($0.name) }
    }

    package static func isIgnorableToolName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ||
            trimmed == "..." ||
            trimmed == "…" ||
            trimmed == "_fn_placeholder" ||
            trimmed == "_call_placeholder" ||
            trimmed == "tool_name" ||
            trimmed == "<tool_name>"
    }

    private static let protocolDebrisPattern = #"<parse_error>.*?(?:</parse_error>|\z)|<reasoning_effort>[^<]*(?:</reasoning_effort>|\z)|</?(?:parse|function_(?:calls|results?)|tool_results?|result)\b[^<>]*>|_\w+_placeholder"#

    private static let codeRegionRegexes = [
        #"(?ms)^[ \t]*(`{3,})[^\r\n]*\r?\n(.*?)(?:^[ \t]*\1`*[ \t]*\r?$|\z)"#,
        #"(?ms)^[ \t]*(~{3,})[^\r\n]*\r?\n(.*?)(?:^[ \t]*\1~*[ \t]*\r?$|\z)"#,
        #"(?s)(`+)(?!`)(.*?)(?<!`)\1(?!`)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let orphanRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:</?(?:tool_use|invoke|parameter)\b|_?(?:tool_use|ool_use)\b[ \t>])"#)
    private static let invokeStartRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:<function_calls>\s*)?<invoke\b"#)
    private static let quotedMarkerRegex = try! NSRegularExpression(pattern: #"(?i)<(?:tool_use|invoke)\b"#)
    private static let nestedMarkerRegex = try! NSRegularExpression(pattern: #"<(?:tool_use|invoke)\b"#)
    private static let formattedMarkerRegex = try! NSRegularExpression(pattern: #"(?is)(?:\*\*|__)\s*<(tool_use|invoke)\b[\s\S]*?</\1>\s*(?:\*\*|__)"#)
    private static let headerRegex = try! NSRegularExpression(pattern: #"(?im)^[ \t]*(?:\d+[ \t]*)?(?:\*\*|__)?[ \t]*Tool[ \t]+Call[ \t]*(?::[ \t]*[A-Za-z0-9_.:-]*)?[ \t]*(?:\*\*|__)?[ \t]*$"#)
    private static let fencedJSONRegex = try! NSRegularExpression(pattern: #"(?is)(?:```|~~~)[ \t]*(?:json)?[ \t]*\r?\n[ \t]*\{[\s\S]*?(?:```|~~~)"#)
    private static let markerRegex = try! NSRegularExpression(pattern: #"<tool_use\s+(?:id="[^"]*"\s+)?name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#)
    private static let idMarkerRegex = try! NSRegularExpression(pattern: #"<tool_use\s+id="([^"]*)"\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#)
    private static let legacyMarkerRegex = try! NSRegularExpression(pattern: #"<tool_use\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#)
    private static let invokeRegex = try! NSRegularExpression(pattern: #"<invoke\s+name="([^"]+)"\s*>([\s\S]*?)</invoke>"#)
    private static let parameterRegex = try! NSRegularExpression(pattern: #"<parameter\s+name="([^"]+)"\s*>([\s\S]*?)</parameter>"#)
    // Overlapping matches let a complete inner call survive an unfinished outer call.
    private static let repairRegionRegex = try! NSRegularExpression(pattern: #"(?=<(?<tag>tool_use|invoke|parameter)\s+(?:id="(?<id>[^"]*)"\s+)?name="(?<name>[^"]+)"\s*>(?<body>(?:\s*"# + parameterRegex.pattern + #"\s*)+|[\s\S]*?)(?:</\k<tag>>|(?=\s*</[\w.:-]+>)|\z))"#)

    /// Control debris is not prose, even when the provider ends inside it.
    /// Keep fenced and inline code and complete calls intact, including their arguments.
    package static func stripProtocolDebris(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"(?is)(```.*?```|~~~.*?~~~|(?<!`)(`+)(?!`).*?(?<!`)\2(?!`)|<tool_use\b[^<>]*>.*?</tool_use>|<invoke\b[^<>]*>.*?</invoke>)|(?:"# + protocolDebrisPattern + ")",
            with: "$1", options: .regularExpression)
    }

    /// Broken or formatted calls never execute or settle as ordinary prose.
    /// The shared loop gives one format nudge before settling incomplete.
    package static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String> = [], parseInvoke: Bool = false
    ) -> ToolCallProtocolViolation? {
        let openAI = parseOpenAI(raw)
        return formattedToolCallViolation(in: raw, toolNames: toolNames, parseInvoke: parseInvoke,
                                          openAI: openAI, calls: openAI ?? parseAnthropic(raw, parseInvoke: true))
    }

    private static func formattedToolCallViolation(
        in raw: String, toolNames: Set<String>, parseInvoke: Bool,
        openAI: [ParsedToolCall]?, calls: [ParsedToolCall]
    ) -> ToolCallProtocolViolation? {
        // Remove complete calls before looking for orphan tags or placeholders.
        // Their arguments may legitimately contain these strings.
        // Fenced code is quoted text, never a call.
        let unfenced = raw.replacingOccurrences(
            of: #"(?s)```.*?```|~~~.*?~~~"#, with: "", options: .regularExpression)
        let remainder = stripToolUseMarkers(unfenced)
        if regexMatches(orphanRegex, in: remainder)
            || (!unfenced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && stripProtocolDebris(unfenced).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (!parseInvoke && regexMatches(invokeStartRegex, in: raw))
            || (openAI != nil && calls.isEmpty)
            || (!calls.isEmpty && executableCalls(calls).isEmpty) {
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }

        // A syntactically valid marker inside a code fence or inline Markdown
        // is still protocol-invalid. Check this before parseAnthropic, whose
        // intentionally unanchored marker regex otherwise finds the inner tag.
        // Inspect the whole code region: <function_calls> and example prose
        // may precede the invoke that the executable parser would find.
        let ns = raw as NSString
        for rx in codeRegionRegexes {
            for match in rx.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                if regexMatches(quotedMarkerRegex, in: ns.substring(with: match.range(at: 2))) {
                    return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
                }
            }
        }
        if regexMatches(formattedMarkerRegex, in: raw) {
            return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
        }

        // Pin the real failure shape observed on Telegram:
        //   **Tool Call: codex_message**
        //   ```json
        //   { ... }
        //   ```
        // Requiring both an exact header line and a following fenced JSON
        // object avoids bouncing ordinary prose that merely discusses calls.
        if regexMatches(headerRegex, in: raw), regexMatches(fencedJSONRegex, in: raw) {
            return ToolCallProtocolViolation(kind: .markdownToolCallBlock)
        }

        // 2026-09-22: a marker whose body is not a JSON object used to run
        // with {} and fail as "missing X", so the model never learned why.
        // Only for a real tool name: anything else is prose quoting the syntax.
        for m in markerRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            guard toolNames.contains(ns.substring(with: m.range(at: 1))) else { continue }
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let codeRanges = codeRegionRegexes.flatMap { rx in
            rx.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        var replacements: [String] = []
        for region in repairRegionRegex.matches(in: raw, range: NSRange(start..., in: raw)) {
            guard !codeRanges.contains(where: { NSLocationInRange(region.range.location, $0) }) else { continue }
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
            // Keep a surrounding Markdown wrapper too. Otherwise an opening
            // fence could stream just before the inner marker is recognized.
            for wrapper in ["```", "~~~", "**", "__", "`"] {
                if let start = prefix.range(of: wrapper, options: [.backwards]) {
                    candidates.append(start)
                }
            }
        }
        return candidates.min { $0.lowerBound < $1.lowerBound }
    }

    /// Visible prose preceding the earliest possible protocol marker, unchanged if absent.
    package static func visiblePrefix(in raw: String) -> String {
        if let marker = earliestPotentialProtocolMarker(in: raw) {
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
    static func parseOpenAI(_ raw: String) -> [ParsedToolCall]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else {
            return nil
        }
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

    // <tool_use> marker (both OAuth-direct adapters emit) + bare JSON content
    // blocks (the Anthropic content-array shape). Marker is now id-bearing:
    //   <tool_use id="toolu_..." name="X">{json}</tool_use>
    // The legacy form `<tool_use name="X">{json}</tool_use>` is still parsed
    // — id falls back to empty so the tool loop can detect and skip the
    // round-trip ID echo.
    /// A marker's JSON object body. Models often write code (a script's
    /// source) with raw newlines or tabs inside a JSON string; those are
    /// escaped and the body read again, so the call runs as written.
    static func markerObject(_ body: String) -> [String: JSONValue]? {
        if case .object(let o)? = try? JSONValue.parse(Data(body.utf8)) { return o }
        var fixed = "", inString = false, escaped = false
        for ch in body {
            if inString, !escaped, ch == "\n" || ch == "\r" || ch == "\t" || ch == "\r\n" {
                fixed += ch == "\t" ? "\\t" : ch == "\r" ? "\\r" : ch == "\r\n" ? "\\r\\n" : "\\n"
                continue
            }
            if escaped { escaped = false } else if ch == "\\" { escaped = inString } else if ch == "\"" { inString.toggle() }
            fixed.append(ch)
        }
        guard fixed != body, case .object(let o)? = try? JSONValue.parse(Data(fixed.utf8)) else { return nil }
        return o
    }

    static func parseAnthropic(_ raw: String, parseInvoke: Bool = false) -> [ParsedToolCall] {
        var positionedCalls: [(Int, ParsedToolCall, Bool)] = []
        let ns = raw as NSString
        // The two marker patterns do not overlap; collect both before sorting.
        for m in idMarkerRegex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            let input = markerObject(body) ?? [:]
            positionedCalls.append((m.range.location, ParsedToolCall(id: id, name: name, input: input), false))
        }
        // Legacy plain-name form. Kept as a back-compat seam.
        for m in legacyMarkerRegex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            // An unclosed legacy marker swallowing a later id-form block.
            if body.contains("<tool_use") { continue }
            let input = markerObject(body) ?? [:]
            positionedCalls.append((m.range.location, ParsedToolCall(id: "", name: name, input: input), false))
        }
        // Claude's own trained form, which Opus 5.5 writes despite the
        // protocol above: <invoke name="X"><parameter name="k">v</parameter></invoke>.
        // Identical repeats in one reply run once.
        if parseInvoke {
            for m in invokeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
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
        }
        if !positionedCalls.isEmpty {
            var seenInvokes: Set<String> = []
            return positionedCalls.sorted { $0.0 < $1.0 }.compactMap { positioned -> ParsedToolCall? in
                let call = positioned.1
                guard positioned.2 else { return call }
                let signature = call.name + ((try? JSONValue.object(call.input).serialize(pretty: false)) ?? "")
                    + call.undeclaredKeys.joined(separator: ",")
                return seenInvokes.insert(signature).inserted ? call : nil
            }
        }
        // Bare JSON content-block / array shape.
        var calls: [ParsedToolCall] = []
        if let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let parsed = try? JSONValue.parse(d) {
            if case .array(let arr) = parsed {
                for item in arr {
                    if case .object(let o) = item,
                       case .string("tool_use") = o["type"] ?? .null,
                       case .string(let name) = o["name"] ?? .null {
                        let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                        calls.append(argumentsCall(id: id, name: name, o["input"] ?? .null))
                    }
                }
            } else if case .object(let o) = parsed,
                      case .string("tool_use") = o["type"] ?? .null,
                      case .string(let name) = o["name"] ?? .null {
                let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                calls.append(argumentsCall(id: id, name: name, o["input"] ?? .null))
            }
        }
        return calls
    }
}

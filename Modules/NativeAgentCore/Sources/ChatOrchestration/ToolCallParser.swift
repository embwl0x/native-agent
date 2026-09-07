import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Parsed tool call

struct ParsedToolCall: Equatable {
    /// Provider-issued call id. Echoed back as `tool_result.tool_use_id`
    /// (Anthropic) or `function_call_output.call_id` (OpenAI). Empty when
    /// the parser couldn't recover one (legacy marker, bare JSON shape).
    let id: String
    let name: String
    let input: [String: JSONValue]
}

// MARK: - Parsing

struct ToolCallProtocolViolation: Equatable {
    enum Kind: Equatable {
        case markdownToolCallBlock
        case formattedToolUseMarker
        case malformedToolUseMarker
    }

    let kind: Kind

    var modelFeedback: String {
        if kind == .malformedToolUseMarker {
            return """
            NativeAgent tool protocol error: your previous response contained a truncated or malformed tool_use marker. That response was not delivered and no tool was executed. Retry now through the provider's native tool-call channel. If no tool is needed, answer the user directly.
            """
        }
        return """
        NativeAgent tool protocol error: your previous response looked like a tool call but used Markdown formatting instead of the executable tool protocol. That response was not delivered and no tool was executed. Retry now by emitting only one or more exact <tool_use name="tool_name">{"arg":"value"}</tool_use> markers, with no Tool Call header, code fence, inline-code/emphasis wrapper, or invented Tool Result. If no tool is needed, answer the user directly.
        """
    }

    var terminalReply: String {
        if kind == .malformedToolUseMarker {
            return "(tool protocol error: the model repeatedly emitted a malformed tool call; no malformed call was delivered or executed)"
        }
        return "(tool protocol error: the model repeatedly formatted a tool call as Markdown; no formatted call was delivered or executed)"
    }
}

enum ToolCallParser {
    /// Try OpenAI shape first (whole-response JSON with tool_calls or
    /// function_call), then `<tool_use id="..." name="...">{json}</tool_use>`
    /// markers (both adapters emit this format), then bare JSON content
    /// blocks `{"type":"tool_use","id":...,"name":"...","input":{...}}`.
    static func parse(_ raw: String) -> [ParsedToolCall] {
        guard formattedToolCallViolation(in: raw) == nil else { return [] }
        if let openai = parseOpenAI(raw) {
            let executable = executableCalls(openai)
            if !executable.isEmpty { return executable }
        }
        let anth = executableCalls(parseAnthropic(raw))
        if !anth.isEmpty { return anth }
        return []
    }

    static func parseIncludingIgnorable(_ raw: String) -> [ParsedToolCall] {
        guard formattedToolCallViolation(in: raw) == nil else { return [] }
        if let openai = parseOpenAI(raw), !openai.isEmpty { return openai }
        let anth = parseAnthropic(raw)
        if !anth.isEmpty { return anth }
        return []
    }

    static func containsOnlyIgnorableCalls(_ raw: String) -> Bool {
        let calls = parseIncludingIgnorable(raw)
        return !calls.isEmpty && executableCalls(calls).isEmpty
    }

    /// Strip `<tool_use ...>...</tool_use>` markers from a raw response so the
    /// prose-only text can be persisted/surfaced. Both id-bearing and legacy
    /// plain-name forms are matched. Shared by the structured tool loop and the
    /// text-compatibility loop (C-L2, 2026-07-18 — formerly byte-identical twins).
    /// Announce-without-act detector (2026-07-19, Kimi K3 Telegram incident):
    /// weak-tool-discipline models end turns with an immediate-action promise
    /// ("on it — checking now") and ZERO tool calls, so nothing happens until
    /// the user prods. Deliberately CONSERVATIVE — short replies only, exact
    /// present-tense phrases; a question to the user or a long substantive
    /// answer never matches. False negatives cost one user nudge (status
    /// quo); false positives burn one extra provider call, so tight wins.
    static let unfulfilledPromisePhrases: [String] = [
        "checking now", "checking that now", "checking it now",
        "let me check", "let me look", "let me pull", "let me fetch",
        "let me grab", "let me see what",
        // Bare "on it." / "on it!" were raw-substring FPs ("I already acted on
        // it.") — dropped here (F2-M2). The em-dash/hyphen continuation forms
        // stay; the bare-acknowledgment case is handled by the final-sentence
        // "on it" gate in looksLikeUnfulfilledActionPromise.
        "on it —", "on it -",
        "i'll check", "i'll look", "i'll pull", "i'll fetch", "i'll dig",
        "looking now", "looking into it now", "pulling it up", "pulling that up",
        "loading it now", "loading them now", "loading that now", "fetching now",
        "give me a moment", "give me a sec", "one moment", "one sec",
    ]

    /// Shape rule (2026-07-19 round 2 — the phrase whitelist alone missed
    /// "going through the actual files now" and "Reading the README now." in
    /// the live incident): a progressive action verb followed within a clause
    /// by "now"/"next", not preceded by a completion word. Completion words
    /// ("just finished running now") stay valid stopping points.
    private static let inProgressShapeRegex = try! NSRegularExpression(
        pattern: #"(?<!finished\s)(?<!done\s)(?<!just\s)(?<!already\s)(?<!stopped\s)\b(reading|checking|looking|going\s+through|pulling|fetching|loading|opening|scanning|digging|reviewing|inspecting|working\s+(?:on|through)|diving\s+(?:in|into)|taking\s+a\s+look|starting\s+(?:on|with))\b[^.!?\n]{0,60}\b(now|next)\b"#,
        options: [.caseInsensitive]
    )

    /// Round 4 (live incident: "Let me actually look at what's built." ended a
    /// turn — an adverb between "let me" and the verb defeated the literal
    /// phrase list). First-person immediate-intent with up to two intervening
    /// words, as the reply's FINAL sentence.
    /// F2-M3 (2026-07-23): go/take/see were REMOVED from the verb alternation —
    /// they bounced decision idioms ("I'll go with option A.", "I'll take that
    /// approach.", "let me see"). Their genuine action forms are already caught
    /// elsewhere ("go through" / "take a look" by inProgressShapeRegex, "let me
    /// see what" by the phrase list), so keeping them here only added FP risk.
    private static let deferredIntentRegex = try! NSRegularExpression(
        pattern: #"\b(let\s+me|i'll|i\s+will|going\s+to|about\s+to)(\s+\w+){0,2}\s+(check|look|pull|fetch|grab|read|dig|scan|open|run|start|load)\b"#,
        options: [.caseInsensitive]
    )

    /// Completion-statement verbs: a final sentence containing one of these is
    /// a report, not a forward reference ("now the tests are green").
    private static let completionVerbTokens: Set<String> = [
        "is", "are", "was", "were", "be", "been", "done", "passed", "green",
        "complete", "completed", "finished", "works", "working", "ready",
        "found", "fixed", "ran", "looks", "shows", "has", "have",
    ]

    /// F2-M1 + F2-L2 (2026-07-23): a final sentence with a PLAIN PAST-TENSE main
    /// verb is a completed REPORT, never an in-progress promise — "Reviewing the
    /// PR, I left 3 comments.", "Running the benchmark took 4 seconds.", "Then
    /// the app crashed." The gerund-first and verbless-forward-reference rules
    /// FP'd on these because completionVerbTokens carried no past-tense reporting
    /// verbs. Detection: any `\w{3,}ed` form OR a curated set of common
    /// irregulars. Deliberately NARROW — future/progressive forms ("I'll go
    /// with") carry no past-tense token, so this exemption never fires on them
    /// and the deferred-intent / gerund rules still bite.
    private static let pastTenseIrregulars: Set<String> = [
        "left", "took", "ran", "went", "got", "found", "made", "saw", "gave",
        "sent", "wrote", "read", "built", "broke", "kept", "held", "came",
        "put", "set", "told", "said", "did",
    ]
    private static let pastTenseEdRegex = try! NSRegularExpression(
        pattern: #"\b\w{3,}ed\b"#,
        options: [.caseInsensitive]
    )
    private static func finalSentenceIsPastTenseReport(_ finalSentence: String) -> Bool {
        let tokens = finalSentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if tokens.contains(where: { pastTenseIrregulars.contains($0) }) { return true }
        let range = NSRange(finalSentence.startIndex..., in: finalSentence)
        return pastTenseEdRegex.firstMatch(in: finalSentence, options: [], range: range) != nil
    }

    /// R7 (live incident 2026-08-17, Telegram session B7ED3E77 msg #6): the
    /// model announced a tool BY NAME as its whole reply — `**Tool: desk_read**`
    /// — neither a promise sentence (R1–R6) nor a parseable marker, so it
    /// shipped to the user as text and nothing ran until User prodded with "?".
    /// Shape: a SHORT reply whose final line is nothing but an invocation
    /// frame around a KNOWN tool name. Conservative on purpose: completed-work
    /// narration ("I used desk_read earlier…") and questions never match.
    static func looksLikeNarratedToolInvocation(
        _ raw: String,
        knownToolNames: Set<String>
    ) -> Bool {
        guard !knownToolNames.isEmpty else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }
        // A genuine question back to the user is a valid stopping point.
        guard !trimmed.contains("?") else { return false }
        guard let lastRaw = trimmed.split(separator: "\n").last else { return false }
        // Strip markdown emphasis/quotes/bullets around the line.
        let line = lastRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`>•- "))
        var candidate = line.lowercased()
        // Optional invocation frame ahead of the name.
        var hasInvocationFrame = false
        for prefix in ["tool call:", "tool:", "calling", "invoking", "running", "using", "call", "run"] {
            if candidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                hasInvocationFrame = true
                break
            }
        }
        let ident = candidate.prefix {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "."
        }
        guard !ident.isEmpty,
              knownToolNames.contains(where: { $0.lowercased() == ident }) else {
            return false
        }
        // The line must be ONLY frame + name (+ optional argument sketch) —
        // a sentence continuing past the name is narration about work, not an
        // attempted call.
        let rest = candidate.dropFirst(ident.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("(") || rest.hasPrefix("with ") else {
            return false
        }
        // A bare tool name with no frame and no call syntax is ambiguous — it
        // can be a legitimate short answer ("Use:\ndesk_read"). Require either
        // an invocation frame or explicit call shape (gpt-5.5 LOW, 2026-08-17).
        return hasInvocationFrame || rest.hasPrefix("(")
    }

    static func looksLikeUnfulfilledActionPromise(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 600 else { return false }
        // A genuine question back to the user is a valid stopping point.
        guard !trimmed.contains("?") else { return false }
        // F2-L1 (2026-07-23): fold curly apostrophes (U+2019, U+02BC) to ASCII
        // so the phrase list and the i'll / let me regexes match the smart-quote
        // variants weak models emit ("I’ll check", "let me…") identically.
        let lower = trimmed.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        // Final stopping sentence — HOISTED above the phrase check (F2-M2) so the
        // phrase list anchors to the terminal clause rather than the whole reply
        // (raw substring matched "on it." inside "I already acted on it.").
        let finalSentence = lower
            .split(whereSeparator: { ".!;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        // Phrase check (F2-M2): anchored to the final sentence, with an `already`
        // report exemption mirroring the regex lookbehinds — "I already acted on
        // it." claims the work is done, so it is a report, not a promise.
        if !finalSentence.contains("already") {
            if unfulfilledPromisePhrases.contains(where: { finalSentence.contains($0) }) {
                return true
            }
            // Bare "on it" only when it IS essentially the whole terminal clause
            // (starts the sentence, ≤4 words) — never a trailing "...acted on it."
            if finalSentence.hasPrefix("on it"),
               finalSentence.split(separator: " ").count <= 4 {
                return true
            }
        }
        let range = NSRange(lower.startIndex..., in: lower)
        if inProgressShapeRegex.firstMatch(in: lower, options: [], range: range) != nil {
            return true
        }
        // Round 5 — THE general announcement shape (live battery catch:
        // "Checking the transcript for that exchange before I answer." ended
        // a turn): a stopping sentence that BEGINS with a bare progressive
        // verb is an announcement — complete answers don't start with a
        // subjectless gerund. Subsumes most earlier shapes; completion-verb
        // stoplist still exempts reports ("Checking finished — all green").
        let gerundStarts: Set<String> = [
            "checking", "reading", "looking", "pulling", "fetching", "loading",
            "opening", "scanning", "digging", "reviewing", "inspecting",
            "searching", "grabbing", "running", "starting", "diving", "going",
        ]
        let fsWords = finalSentence.split(separator: " ").map(String.init)
        // Round 6 (live battery catch, 2026-07-20: "Now loading the
        // file/git/telegram tools so I can finish the battery for real."
        // ended a 20-call marathon turn at 11): a filler adverb in front of
        // the gerund slipped past the gerund-FIRST rule. Strip leading
        // filler tokens before the gerund check; the word-count bound
        // applies to what remains.
        let fillerLead: Set<String> = [
            "now", "next", "then", "first", "so", "and", "ok", "okay", "alright",
        ]
        let leadPunctuation = CharacterSet(charactersIn: ",:;—–-")
        let fsCore = Array(fsWords.drop(while: {
            fillerLead.contains($0.trimmingCharacters(in: leadPunctuation))
        }))
        if let first = fsCore.first, gerundStarts.contains(first),
           fsCore.count >= 2, fsCore.count <= 14,
           !fsCore.contains(where: { completionVerbTokens.contains($0) }),
           // F2-M1: "Running the benchmark took 4 seconds." / "Reviewing the PR,
           // I left 3 comments." are past-tense REPORTS despite the gerund lead.
           !finalSentenceIsPastTenseReport(finalSentence) {
            return true
        }
        // Adverb-tolerant deferred intent in the STOPPING sentence ("let me
        // actually look at what's built") — round 4.
        let fsRange = NSRange(finalSentence.startIndex..., in: finalSentence)
        if finalSentence.count <= 90,
           deferredIntentRegex.firstMatch(in: finalSentence, options: [], range: fsRange) != nil {
            return true
        }
        // Verbless forward-reference fragment as the STOPPING sentence
        // ("Now the issues and the code itself.") — round 3, live incident:
        // no progressive verb, no promise phrase, still an announced next
        // step with nothing delivered. Conservative: short final sentence,
        // starts with a forward word + determiner, zero completion verbs.
        let words = finalSentence.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 8 else { return false }
        let forwardStarts = ["now", "next", "then", "onto"]
        let determiners = ["the", "those", "these", "that", "to", "onto", "for", "into"]
        guard forwardStarts.contains(words[0]), determiners.contains(words[1]) else { return false }
        // F2-L2: "Then the app crashed." is a past-tense report, not a promise.
        if finalSentenceIsPastTenseReport(finalSentence) { return false }
        return !words.contains(where: { completionVerbTokens.contains($0) })
    }

    /// Completion-contract remedy for the STRUCTURED tool loop's announce-
    /// without-act bounce (F2-M4, 2026-07-23). The structured lane always speaks
    /// the provider's native tool-call convention, so the wording is modeled on
    /// the native-lane remedy at ChatOrchestrationClient+TextCompatibility —
    /// NEVER the text marker protocol.
    static func structuredAnnounceContractRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "NativeAgent completion contract: your reply describes work as in "
                + "progress but this runtime has NO background execution — work you "
                + "narrate without a tool call never happens, and the user is left "
                + "waiting. Continue NOW in this same turn: make the next tool call, "
                + "or deliver your complete final answer."
        }
        return "SECOND bounce — you again narrated instead of acting. This is your "
            + "last continuation: either make the tool call for the next step right "
            + "now, or give the user your complete final answer (including any "
            + "concrete blocker). Do not describe future work."
    }

    /// Empty-reply recovery remedy for the STRUCTURED tool loop (FIX 1, B1.1,
    /// 2026-07-23). Sibling of the text-compat `emptyReplyNudgeCount` recovery
    /// (ChatOrchestrationClient+TextCompatibility): a provider that returns an
    /// empty text reply AND zero tool calls (e.g. it did the whole move inside a
    /// thinking block and emitted no output) is not a valid final — nothing
    /// reached the user or the tool runtime. The structured lane always speaks
    /// the provider's native tool-call convention, so the wording mirrors the
    /// native-lane (`ridesNativeTools`) empty-reply nudge, NEVER the text marker
    /// protocol. Bounded at two bounces by the caller; the third empty reply is
    /// accepted as final so a provider that only ever thinks can never loop.
    static func structuredEmptyReplyRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "Your previous response contained only internal reasoning and "
                + "NO output — nothing reached the user or the tool runtime, so "
                + "whatever you decided never happened. Respond again NOW: either "
                + "make the tool call(s) for the action you chose, or deliver your "
                + "complete answer as plain prose. The response must never be empty."
        }
        return "SECOND empty response — again nothing reached the user or the tool "
            + "runtime. This is your last continuation: make the tool call(s) for "
            + "the next step right now, or deliver your complete final answer as "
            + "plain prose. Your response must not be empty."
    }

    static func stripToolUseMarkers(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"<tool_use\s+id="[^"]*"\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
            #"<tool_use\s+name="[^"]+"\s*>[\s\S]*?</tool_use>"#,
        ]
        for pattern in patterns {
            if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = s as NSString
                s = rx.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }
        return s
    }

    static func executableCalls(_ calls: [ParsedToolCall]) -> [ParsedToolCall] {
        calls.filter { !isIgnorableToolName($0.name) }
    }

    static func isIgnorableToolName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ||
            trimmed == "..." ||
            trimmed == "…" ||
            trimmed == "tool_name" ||
            trimmed == "<tool_name>"
    }

    /// Markdown pseudo-tool calls are never executable. They previously fell
    /// through as ordinary assistant prose, which made a failed action look
    /// successful to both the model and the user. Keep the executable parser
    /// strict and let each tool-loop owner feed `modelFeedback` into its next
    /// provider call instead of surfacing the malformed response.
    static func formattedToolCallViolation(in raw: String) -> ToolCallProtocolViolation? {
        // Live Telegram incident (2026-08-14): the provider emitted
        // `ool_use name="commit_memory">…</tool_use>`, dropping the opening
        // `<t`. It was neither executable nor caught by the exact-marker
        // detector, so it shipped as assistant prose. Require an opening-line
        // protocol shape, a name attribute, and the real closing tag; ordinary
        // discussion of the word "tool_use" remains valid prose.
        let malformedOpeningPattern = #"(?is)(?:^|[\r\n])[ \t]*(?:tool_use|ool_use)[ \t]+(?:id=\"[^\"]*\"[ \t]+)?name=\"[^\"]+\"[ \t]*>[\s\S]*?</tool_use>"#
        if regexMatches(malformedOpeningPattern, in: raw) {
            return ToolCallProtocolViolation(kind: .malformedToolUseMarker)
        }

        // A syntactically valid marker inside a code fence or inline Markdown
        // is still protocol-invalid. Check this before parseAnthropic, whose
        // intentionally unanchored marker regex otherwise finds the inner tag.
        let formattedMarkerPatterns = [
            #"(?is)(?:```|~~~)[^\r\n]*\r?\n\s*<tool_use\b[\s\S]*?</tool_use>\s*(?:```|~~~)"#,
            #"(?is)`\s*<tool_use\b[\s\S]*?</tool_use>\s*`"#,
            #"(?is)(?:\*\*|__)\s*<tool_use\b[\s\S]*?</tool_use>\s*(?:\*\*|__)"#,
        ]
        if formattedMarkerPatterns.contains(where: { regexMatches($0, in: raw) }) {
            return ToolCallProtocolViolation(kind: .formattedToolUseMarker)
        }

        // Pin the real failure shape observed on Telegram:
        //   **Tool Call: codex_message**
        //   ```json
        //   { ... }
        //   ```
        // Requiring both an exact header line and a following fenced JSON
        // object avoids bouncing ordinary prose that merely discusses calls.
        let headerPattern = #"(?im)^[ \t]*(?:\d+[ \t]*)?(?:\*\*|__)?[ \t]*Tool[ \t]+Call[ \t]*(?::[ \t]*[A-Za-z0-9_.:-]*)?[ \t]*(?:\*\*|__)?[ \t]*$"#
        let fencedJSONPattern = #"(?is)(?:```|~~~)[ \t]*(?:json)?[ \t]*\r?\n[ \t]*\{[\s\S]*?(?:```|~~~)"#
        if regexMatches(headerPattern, in: raw), regexMatches(fencedJSONPattern, in: raw) {
            return ToolCallProtocolViolation(kind: .markdownToolCallBlock)
        }
        return nil
    }

    /// Earliest text that could become an executable or malformed tool
    /// protocol block. Streaming paths hold this suffix until the completed
    /// iteration can be parsed, so marker-shaped text never reaches a draft.
    static func earliestPotentialProtocolMarker(in raw: String) -> Range<String.Index>? {
        let needles = [
            "<tool", "tool_use name=\"", "ool_use name=\"",
            "**tool call", "__tool call", "tool call:",
        ]
        var candidates = needles.compactMap { needle in
            raw.range(of: needle, options: [.caseInsensitive])
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
    static func visiblePrefix(in raw: String) -> String {
        if let marker = earliestPotentialProtocolMarker(in: raw) {
            return String(raw[..<marker.lowerBound])
        }
        return raw
    }

    /// Bound the legacy grown-prompt echo while preserving enough of the
    /// model's rejected output to retry the intended tool and arguments.
    static func feedbackIncludingRejectedOutput(
        _ raw: String,
        violation: ToolCallProtocolViolation,
        limit: Int = 12_000
    ) -> String {
        let bounded: String
        if raw.count <= limit {
            bounded = raw
        } else {
            let end = raw.index(raw.startIndex, offsetBy: limit)
            bounded = String(raw[..<end]) + "\n[rejected output truncated]"
        }
        return """
        \(violation.modelFeedback)

        Rejected assistant output (for retry context only):
        \(bounded)
        """
    }

    private static func regexMatches(_ pattern: String, in raw: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
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
                let input = extractArgumentsObject(fn["arguments"] ?? .null)
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
            return calls
        }
        if case .object(let fn) = obj["function_call"] ?? .null,
           case .string(let name) = fn["name"] ?? .null {
            let input = extractArgumentsObject(fn["arguments"] ?? .null)
            let id: String = {
                if case .string(let s) = fn["call_id"] ?? .null { return s }
                return ""
            }()
            return [ParsedToolCall(id: id, name: name, input: input)]
        }
        return nil
    }

    static func extractArgumentsObject(_ v: JSONValue) -> [String: JSONValue] {
        switch v {
        case .object(let o): return o
        case .string(let s):
            if let d = s.data(using: .utf8),
               let parsed = try? JSONValue.parse(d),
               case .object(let o) = parsed {
                return o
            }
            return [:]
        default: return [:]
        }
    }

    // <tool_use> marker (both OAuth-direct adapters emit) + bare JSON content
    // blocks (the Anthropic content-array shape). Marker is now id-bearing:
    //   <tool_use id="toolu_..." name="X">{json}</tool_use>
    // The legacy form `<tool_use name="X">{json}</tool_use>` is still parsed
    // — id falls back to empty so the tool loop can detect and skip the
    // round-trip ID echo.
    static func parseAnthropic(_ raw: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        // ID-bearing form FIRST so any legacy plain-name marker doesn't
        // greedy-consume an id-bearing block when both happen to be present.
        let idPattern = #"<tool_use\s+id="([^"]*)"\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#
        if let rx = try? NSRegularExpression(pattern: idPattern, options: []) {
            let ns = raw as NSString
            for m in rx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                let name = ns.substring(with: m.range(at: 2))
                let body = ns.substring(with: m.range(at: 3))
                var input: [String: JSONValue] = [:]
                if let d = body.data(using: .utf8),
                   let parsed = try? JSONValue.parse(d),
                   case .object(let o) = parsed {
                    input = o
                }
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
            if !calls.isEmpty { return calls }
        }
        // Legacy plain-name form. Kept as a back-compat seam.
        let legacyPattern = #"<tool_use\s+name="([^"]+)"\s*>([\s\S]*?)</tool_use>"#
        if let rx = try? NSRegularExpression(pattern: legacyPattern, options: []) {
            let ns = raw as NSString
            for m in rx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let body = ns.substring(with: m.range(at: 2))
                var input: [String: JSONValue] = [:]
                if let d = body.data(using: .utf8),
                   let parsed = try? JSONValue.parse(d),
                   case .object(let o) = parsed {
                    input = o
                }
                calls.append(ParsedToolCall(id: "", name: name, input: input))
            }
            if !calls.isEmpty { return calls }
        }
        // Bare JSON content-block / array shape.
        if let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let parsed = try? JSONValue.parse(d) {
            if case .array(let arr) = parsed {
                for item in arr {
                    if case .object(let o) = item,
                       case .string("tool_use") = o["type"] ?? .null,
                       case .string(let name) = o["name"] ?? .null {
                        let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                        var input: [String: JSONValue] = [:]
                        if case .object(let inObj) = o["input"] ?? .null { input = inObj }
                        calls.append(ParsedToolCall(id: id, name: name, input: input))
                    }
                }
            } else if case .object(let o) = parsed,
                      case .string("tool_use") = o["type"] ?? .null,
                      case .string(let name) = o["name"] ?? .null {
                let id: String = { if case .string(let s) = o["id"] ?? .null { return s } else { return "" } }()
                var input: [String: JSONValue] = [:]
                if case .object(let inObj) = o["input"] ?? .null { input = inObj }
                calls.append(ParsedToolCall(id: id, name: name, input: input))
            }
        }
        return calls
    }
}

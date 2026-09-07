import Foundation
import NaturalLanguage

extension SwiftNativeKnowledgeGraphIndexer {
    public nonisolated static func extractEntities(
        from content: String,
        knownPeople: [String] = []
    ) -> [KnowledgeGraphExtractedEntity] {
        let summary = "Mentioned in memory: \(clip(content, limit: 220))"
        var ordered: [KnowledgeGraphExtractedEntity] = []
        var seen: Set<String> = []

        func add(_ rawName: String, forcedType: String? = nil) {
            guard let name = cleanEntityName(canonicalFileEntityName(rawName)) else { return }
            let type = forcedType ?? inferType(name)
            // One node per name. The same name under two types ("Agent" as a
            // person AND a concept) is how the graph grew duplicate hubs; the
            // first lane to claim a name wins, and people are added first.
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(KnowledgeGraphExtractedEntity(name: name, type: type, summary: summary))
        }

        for person in knownPeople where !person.isEmpty && knownTermMentioned(person, in: content) {
            add(person, forcedType: "person")
        }
        for term in knownTerms {
            // 2026-07-21 audit: the bare caseInsensitive substring match had
            // no word boundary, so "Apple" matched "pineapple" (and any
            // other word containing a known term). Match on word boundaries
            // instead. (Diacritic-insensitivity is dropped with the move to
            // NSRegularExpression — no known term carries diacritics.)
            if knownTermMentioned(term.name, in: content) {
                add(term.name, forcedType: term.type)
            }
        }

        for match in regexCaptures(#"`([^`]{2,80})`"#, in: content) {
            // `tests`, `Tests`, `main`: a bare word in backticks is prose
            // emphasis or a directory name, not an entity. Identifiers carry
            // punctuation, a digit, or a space ("git ls-files", "USER.md").
            if match.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil { continue }
            add(match)
        }
        for match in regexMatches(#"\b[A-Za-z0-9_./-]+\.(?:app|md|json|swift|sqlite|mlpackage|mlmodelc)\b"#, in: content) {
            add(match)
        }
        // User, 2026-09-05: "the graph is probably messed up with the way she
        // was writing memories." It was: two capitalisation lanes here turned
        // "Existing", "Fails SOFT" and "VERIFICATION DISCIPLINE" into concept
        // nodes. People, places and organisations now come from the
        // on-device name tagger; a capital letter is not an entity.
        // The people this store is about are known by name, whatever the
        // tagger makes of a short row: the primary user (and any name the
        // caller passes) is a person when mentioned whole.
        for (name, type) in taggedNames(in: content, knownPeople: knownPeople) {
            add(name, forcedType: type)
        }

        return Array(ordered.prefix(24))
    }

    /// Named entities the system's tagger is sure of — personal, place and
    /// organisation names, joined across words ("NativeAgent Contributors", "New York") —
    /// minus the shapes it gets wrong on short memory rows. Every rule in
    /// `taggedNameIsCredible` is a failure observed in the live store on
    /// 2026-09-05 ("Judge", "Nudge", "KG upgrades", "Greet User", "AI", "the
    /// Sky", "Pacific time", "Agentic Systems Architect"). User: "Memory is
    /// important. Get this right."
    private nonisolated static func taggedNames(
        in content: String,
        knownPeople: [String]
    ) -> [(String, String)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = content
        // A two-line memory is too short for language detection; without a
        // language the tagger returns nothing. Detect, and fall back to English.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(content)
        tagger.setLanguage(recognizer.dominantLanguage ?? .english, range: content.startIndex..<content.endIndex)
        var found: [(String, String)] = []
        tagger.enumerateTags(
            in: content.startIndex..<content.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            let name = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { return true }
            let type: String
            switch tag {
            case .personalName?: type = "person"
            case .placeName?: type = "place"
            case .organizationName?: type = "organization"
            default: return true
            }
            guard taggedNameIsCredible(name, type: type, range: range, in: content, knownPeople: knownPeople) else {
                return true
            }
            found.append((name, type))
            return true
        }
        return found
    }

    private nonisolated static let nameParticles: Set<String> = [
        "de", "van", "von", "der", "den", "di", "da", "la", "le", "du", "of", "y", "and", "del", "al", "bin", "ibn",
    ]
    private nonisolated static let roleNouns: Set<String> = [
        "architect", "staff", "officer", "engineer", "manager", "assistant", "director", "chief",
        "princess", "queen", "doll", "lead", "head", "president", "secretary",
    ]
    private nonisolated static let attributivePlaceFollowers: Set<String> = [
        "time", "timezone", "style", "manual", "standard",
    ]

    /// False when a tagged name is one of the tagger's known mistakes on a
    /// memory row. A known person is always credible.
    nonisolated static func taggedNameIsCredible(
        _ name: String,
        type: String,
        range: Range<String.Index>,
        in content: String,
        knownPeople: [String]
    ) -> Bool {
        let tokens = name.split(separator: " ").map(String.init)
        let lowerKnown = knownPeople.map { $0.lowercased() }
        if lowerKnown.contains(name.lowercased()) { return true }
        // Glue: "KG upgrades", "User values Agent" — a lowercase word inside a
        // name is the tagger joining a verb or noun onto a capital.
        if tokens.count > 1,
           tokens.contains(where: { ($0.first?.isLowercase ?? false) && !nameParticles.contains($0.lowercased()) }) {
            return false
        }
        // A known person glued to a leading verb ("Greet User", "Reuse User").
        // "User Rogan" leads with the known name and stays a person.
        if type == "person", tokens.count > 1,
           let known = lowerKnown.first(where: { tokens.map { $0.lowercased() }.contains($0) }),
           tokens.first?.lowercased() != known {
            return false
        }
        // Acronyms: "AI", "API", "CLI", "APFS" are not organisations. Known
        // terms (APNS, MCP) were added before the tagger ran.
        if tokens.count == 1, name.count <= 5, name == name.uppercased(),
           name.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return false
        }
        // 2026-09-06: the same acronym glued to its neighbour. On "Codex SSHes
        // into the VM through an SSH Bridge" the tagger returns "Codex SSHes"
        // and "SSH Bridge" as organisations: a verb-inflected acronym, and an
        // acronym plus the next capital. `isAcronymInflectedToken` only ever
        // guarded the title-case lane, which was removed in v5, so nothing
        // caught these once people/places/organisations came from the tagger.
        // An acronym is not an organisation on its own (rule above); it does
        // not become one by acquiring a neighbour.
        if tokens.count > 1, tokens.contains(where: isAcronymFragmentToken) {
            return false
        }
        // A title, not an organisation: "Agentic Systems Architect".
        if type == "organization", tokens.count > 1,
           let last = tokens.last?.lowercased(), roleNouns.contains(last) {
            return false
        }
        let before = content[content.startIndex..<range.lowerBound]
        let after = content[range.upperBound..<content.endIndex]
        let prevWord = before.split(whereSeparator: { !$0.isLetter && $0 != "\'" }).last.map { String($0).lowercased() }
        let nextWord = after.split(whereSeparator: { !$0.isLetter }).first.map { String($0).lowercased() }
        // "the Sky" (Fear the Sky): an article before a single capital is a
        // common noun the tagger capitalised into a name.
        if tokens.count == 1, type != "person", let prevWord, ["the", "a", "an"].contains(prevWord) {
            return false
        }
        // "Pacific time", "Chicago style": a place used as an adjective.
        if type == "place", let nextWord, attributivePlaceFollowers.contains(nextWord) {
            return false
        }
        // A sentence-initial single word ("Judge glass…", "Nudge it…",
        // "Acceptance requires…") is capitalised because sentences are, not
        // because it is a name — unless the same word also appears
        // mid-sentence in this row.
        if tokens.count == 1, isSentenceInitial(range.lowerBound, in: content) {
            // A person at the start of a sentence is usually its subject:
            // "Sarah is User's sister", "Sarah often visits", "Sarah, User's
            // sister,", "Sarah's birthday", "Sarah and Mike". The imperative
            // mistakes ("Judge glass…", "Nudge it…", "Greet User") put a noun,
            // pronoun, determiner or adjective right after the word instead.
            // (Codex review 2026-09-05: the blanket rule rejected new people.)
            if type == "person" {
                let rest = content[range.upperBound...]
                let trimmed = rest.drop(while: { $0 == " " })
                if trimmed.hasPrefix("'s") || trimmed.hasPrefix("’s") || trimmed.first == "," {
                    return true
                }
                if let nextStart = trimmed.first.map({ _ in trimmed.startIndex }) {
                    let lexical = NLTagger(tagSchemes: [.lexicalClass])
                    lexical.string = content
                    let tag = lexical.tag(at: nextStart, unit: .word, scheme: .lexicalClass).0
                    switch tag {
                    case .noun?, .pronoun?, .determiner?, .adjective?, .number?:
                        return false
                    default:
                        return true
                    }
                }
                return true
            }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let whole = NSRange(content.startIndex..., in: content)
            let midSentence = regex.matches(in: content, range: whole).contains { match in
                guard let r = Range(match.range, in: content) else { return false }
                return !isSentenceInitial(r.lowerBound, in: content)
            }
            if !midSentence { return false }
        }
        return true
    }

    /// True when only whitespace, or a sentence terminator / bullet followed
    /// by whitespace, precedes `index`.
    private nonisolated static func isSentenceInitial(_ index: String.Index, in content: String) -> Bool {
        let before = content[content.startIndex..<index]
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        return ".!?:;•-*)".contains(last)
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 0), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Whole-word, case-insensitive mention check for `knownTerms`. Word
    /// boundaries keep "Apple" from firing inside "pineapple" while still
    /// matching "Apple's" / "(Apple)". All known terms start and end with a
    /// word character, so `\b…\b` is the correct frame.
    private static func knownTermMentioned(_ term: String, in content: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.firstMatch(in: content, range: range) != nil
    }

    private static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[r])
        }
    }

    private static func cleanEntityName(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
        guard !collapsed.isEmpty, collapsed.count <= 80 else { return nil }
        let lower = collapsed.lowercased()
        guard !entityStopwords.contains(lower) else { return nil }
        guard collapsed.rangeOfCharacter(from: .letters) != nil else { return nil }
        let wordCount = collapsed.split(separator: " ").count
        guard wordCount <= 4 else { return nil }
        return collapsed
    }

    /// Persona-document paths and their bare filenames are one entity. Keep
    /// this deliberately narrow: collapsing arbitrary same-basename paths
    /// would merge unrelated source files from different repositories.
    private static func canonicalFileEntityName(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let upper = basename.uppercased()
        return canonicalPersonaDocuments[upper] ?? raw
    }

    /// A token the tagger should not have joined to a neighbour: a short
    /// all-caps acronym ("SSH", "VM" — the same shape and bound the
    /// single-token acronym rule rejects) or one inflected as a verb
    /// ("SSHes"). 2026-09-06.
    private nonisolated static func isAcronymFragmentToken(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters.count <= 5, letters.allSatisfy(\.isUppercase) { return true }
        return isAcronymInflectedToken(token)
    }

    private static func isAcronymInflectedToken(_ token: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^[A-Z]{2,}[a-z]+$"#) else {
            return false
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, range: range) != nil
    }

    private static func inferType(_ name: String) -> String {
        let lower = name.lowercased()
        if ["user", "the user", "assistant", "the assistant"].contains(lower) {
            return "person"
        }
        if ["nativeagent", "openclaw", "hermes", "clawdeck"].contains(lower) {
            return "project"
        }
        if lower.hasSuffix(".md") || lower.hasSuffix(".json") || lower.hasSuffix(".swift")
            || lower.hasSuffix(".app") || lower.hasSuffix(".sqlite")
            || ["swift", "coreml", "core ml", "macos", "telegram", "openai", "anthropic", "tradingview", "apns", "mcp"].contains(lower) {
            return "tool"
        }
        if lower == "apple" { return "organization" }
        if lower.contains("launch") || lower.contains("sunday") || lower.contains("rem cycle") {
            return "event"
        }
        return "concept"
    }

    private static let knownTerms: [(name: String, type: String)] = [
        ("NativeAgent", "project"),
        ("Claude", "tool"),
        ("GPT", "tool"),
        ("Astra", "tool"),
        ("Gemini", "tool"),
        ("Kimi", "tool"),
        ("Grok", "tool"),
        ("Mistral", "tool"),
        ("Llama", "tool"),
        ("DeepSeek", "tool"),
        ("Swift", "tool"),
        ("CoreML", "tool"),
        ("Core ML", "tool"),
        ("Apple", "organization"),
        ("macOS", "tool"),
        ("Telegram", "tool"),
        ("OpenAI", "tool"),
        ("Anthropic", "tool"),
        ("TradingView", "tool"),
        ("APNS", "tool"),
        ("MCP", "tool"),
        ("Hermes", "project"),
        ("OpenClaw", "project"),
        ("ClawDeck", "project"),
        ("SOUL.md", "tool"),
        ("VOICE.md", "tool"),
        ("USER.md", "tool"),
        ("GROWTH.md", "tool"),
        ("AGENTS.md", "tool"),
    ]

    private static let canonicalPersonaDocuments: [String: String] = [
        "SOUL.MD": "SOUL.md",
        "VOICE.MD": "VOICE.md",
        "USER.MD": "USER.md",
        "GROWTH.MD": "GROWTH.md",
        "AGENTS.MD": "AGENTS.md",
    ]

    private static let entityStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "for", "from", "how",
        "i", "i'm", "im", "in", "is", "it", "its", "listen", "no", "not", "of",
        "ok", "okay", "on", "or", "so", "that", "the", "then", "there",
        "this", "to", "we", "what", "when", "why", "yeah", "yes", "you",
        "your", "user", "the user",
        // 2026-07-02 audit: the daemon-era extractor let bare pronouns
        // become concept entities ("You" ×8, "We" ×4, "He" ×1 purged from
        // the live graph). The list above already blocked we/you; close
        // the rest of the pronoun class so no capture path can mint one.
        "he", "she", "her", "him", "his", "hers", "they", "them", "their",
        "theirs", "us", "our", "ours", "me", "my", "mine", "these", "those",
        // 2026-07-21 audit: the capitalized-phrase regex mints any
        // sentence-initial capitalized word as an entity, so calendar words
        // and sentence-initial imperative/filler words became junk concept
        // entities ("Today", "Remember", "Update", "Monday", "January").
        // Same whole-phrase lowercase match as the pronoun class above — a
        // word here can never be minted as a standalone entity, but a real
        // multi-word name containing it ("May Lee") still can.
        // Days + months (full and common abbreviated forms).
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec",
        // Relative-day + sentence-initial filler/imperatives.
        "today", "tomorrow", "yesterday", "tonight", "now", "next",
        "last", "first", "finally", "also", "just", "still", "again",
        "remember", "reminder", "update", "updated", "note", "noted",
        "todo", "fyi", "btw",
        // Fresh-install evidence (2026-07-25): repetition alone must not
        // rehabilitate common sentence-leading verbs, emphasis adjectives,
        // or spelled-out counts as named entities. Multiword names remain
        // unaffected because stopwords are matched against the whole phrase.
        "do", "done", "expected", "hard", "nightly", "rewrote",
        "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve",
    ]
}

import Foundation
import NaturalLanguage
// Blueprint: | `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractCorpus`, `taggedNameIsCredible` |

extension SwiftNativeKnowledgeGraphIndexer {
    /// Lowercased alias to the one entity it names: that entity's name and its one type, and the alias as the text wrote it.
    typealias StatedAliases = [String: (name: String, type: String, alias: String)]

    /// Each text's entities, with every alias any of the texts states merged into one entity wherever either name is written.
    nonisolated static func extractCorpus(_ contents: [String], knownPeople: [String],
                                          knownAgents: [String: String]) -> [[KnowledgeGraphExtractedEntity]] {
        let found = contents.map { namesIn($0, knownPeople: knownPeople, knownAgents: knownAgents) }
        let aliases = statedAliases(zip(contents, found).map { (content: $0, entities: $1) }, knownPeople: knownPeople,
                                    knownAgents: knownAgents)
        return zip(contents, found).map {
            resolvingAliases($1, in: $0, aliases: aliases, knownPeople: knownPeople, knownAgents: knownAgents)
        }
    }

    /// The names one text yields, each typed only by what the text says of it: a known person, one of the agent's contacts (an agent,
    /// whichever of its names is written), the tagger's reading of the sentence, or a file's own extension. A name with no stated kind stays
    /// a concept; no fixed table of names assigns a kind.
    nonisolated static func namesIn(_ content: String, knownPeople: [String],
                                    knownAgents: [String: String] = [:]) -> [KnowledgeGraphExtractedEntity] {
        let summary = "Mentioned in memory: \(clip(content, limit: 220))"
        var ordered: [KnowledgeGraphExtractedEntity] = []
        var seen: Set<String> = []

        func add(_ rawName: String, forcedType: String? = nil) {
            guard var name = cleanEntityName(canonicalFileEntityName(rawName)) else { return }
            var type = forcedType ?? inferType(name)
            // A contact's name, handle, host or distinctive first word is that contact: one agent entity under its own name.
            if let contact = knownAgents[name.lowercased()] {
                name = contact
                type = "agent"
            }
            // One node per name: people are added first, and the first type to claim a name wins.
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(KnowledgeGraphExtractedEntity(name: name, type: type, summary: summary))
        }

        for person in knownPeople where !person.isEmpty && knownTermMentioned(person, in: content) {
            add(person, forcedType: "person")
        }
        // Longest first, so "Grok Bot" is found as itself before its first word.
        for term in knownAgents.keys.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
        where knownTermMentioned(term, in: content) {
            add(term)
        }
        // Capitalization alone cannot establish an entity; known whole-name mentions override the tagger.
        let tagged = taggedNames(in: content, knownPeople: knownPeople)
        // A familiar name is found even where the tagger misses it, but its kind is still the sentence's.
        for term in knownTerms where content.range(of: term.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            add(term.name, forcedType: tagged.first { $0.0.lowercased() == term.name.lowercased() }?.1)
        }

        for match in regexCaptures(#"`([^`]{2,80})`"#, in: content) {
            // Bare backticked words may be prose or directories; require punctuation, digits or spaces to identify code entities.
            if match.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil { continue }
            add(match)
        }
        for match in regexMatches(#"\b[A-Za-z0-9_./-]+\.(?:app|md|json|swift|sqlite|mlpackage|mlmodelc)\b"#, in: content) {
            add(match)
        }
        for (name, type) in tagged {
            add(name, forcedType: type)
        }

        return Array(ordered.prefix(24))
    }

    /// Pairs of names a text explicitly says are one, as people say a name: "A, aka / also known as / known as / also called B", "A is B",
    /// "A is X's B", "A is X's name for B", "X's B is named / called / known as A", "B, named / called A", "B goes by A". Both must be names
    /// the text yields, so a kind word ("Agent is User's agent") merges nothing, and a parenthesis or a list is never an alias.
    nonisolated static func statedAliasPairs(in content: String, names: [String]) -> [(String, String)] {
        let byKey = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        guard byKey.count > 1 else { return [] }
        let alternation = byKey.values.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let name = "(?<![\\p{L}\\p{N}])(\(alternation))(?![\\p{L}\\p{N}]|['’]s\\b)"
        let owner = "(?:(?:my|your|our|his|her|their)\\s+|(?!(?:it|that|what|there|here|who|he|she|let)['’]s)[\\p{L}\\p{N}]+['’]s\\s+)"
        let aka = "(?:aka|a\\.k\\.a\\.?|also known as|known as|also called)"
        // The second name ends its clause, so "Swift is my Apple language" never makes Swift and Apple one.
        let ends = "(?=\\s*(?:[.,;:!?)\"”'’\\-–—]|$)|\\s+(?:and|but|who|which|that|so|because)\\b)"
        let quote = "[\"“'‘]?"
        let forms = [
            "\(name)\\s*,?\\s*\(aka)\\s+\(owner)?\(name)\(ends)",
            "\(name)\\s+(?:is|was)\\s+(?:just\\s+|simply\\s+|really\\s+)?\(owner)?(?:name\\s+for\\s+\(owner)?)?\(name)\(ends)",
            "\(name)\\s+(?:is|was)\\s+(?:also\\s+)?(?:named|called|nicknamed|known\\s+as)\\s+\(quote)\(name)\(ends)",
            "\(name)\\s*,\\s*(?:named|called|nicknamed)\\s+\(quote)\(name)\(ends)",
            "\(name)\\s+(?:goes|went)\\s+by\\s+\(quote)\(name)\(ends)",
        ]
        let whole = NSRange(content.startIndex..., in: content)
        var pairs: [(String, String)] = []
        for form in forms {
            guard let regex = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: content, range: whole) {
                guard let first = Range(match.range(at: 1), in: content), let second = Range(match.range(at: 2), in: content),
                      let a = byKey[content[first].lowercased()], let b = byKey[content[second].lowercased()],
                      a.lowercased() != b.lowercased() else { continue }
                pairs.append((a, b))
            }
        }
        return pairs
    }

    /// Every alias the texts state, each mapped to the one name its group keeps (a known person if the group holds one, else a contact,
    /// else the name stated first) and the one type it has, decided once: a person if the group holds a known person, an agent if it holds
    /// a contact, else the first stated kind any of its names has in the texts, else a concept.
    nonisolated static func statedAliases(_ texts: [(content: String, entities: [KnowledgeGraphExtractedEntity])],
                                          knownPeople: [String], knownAgents: [String: String] = [:]) -> StatedAliases {
        var parent: [String: String] = [:]
        var written: [String: String] = [:]
        var order: [String] = []
        func root(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        for text in texts {
            for (a, b) in statedAliasPairs(in: text.content, names: text.entities.map(\.name)) {
                for name in [a, b] where written[name.lowercased()] == nil {
                    written[name.lowercased()] = name
                    parent[name.lowercased()] = name.lowercased()
                    order.append(name.lowercased())
                }
                let (left, right) = (root(a.lowercased()), root(b.lowercased()))
                if left != right { parent[right] = left }
            }
        }
        var groups: [String: [String]] = [:]
        for key in order { groups[root(key), default: []].append(key) }
        let people = knownPeople.map { $0.lowercased() }
        let contacts = Set(knownAgents.values.map { $0.lowercased() })
        var aliases: StatedAliases = [:]
        for members in groups.values {
            let kept = people.first { members.contains($0) } ?? members.first { contacts.contains($0) } ?? members[0]
            let name = knownPeople.first { $0.lowercased() == kept } ?? knownAgents.values.first { $0.lowercased() == kept }
                ?? written[kept] ?? kept
            let stated = texts.lazy.flatMap { $0.entities }.first { members.contains($0.name.lowercased()) && $0.type != "concept" }?.type
            let type = people.contains(kept) ? "person" : contacts.contains(kept) ? "agent" : stated ?? "concept"
            for key in members where key != kept { aliases[key] = (name, type, written[key] ?? key) }
        }
        return aliases
    }

    /// Names stated as one become that one entity, under the name its group keeps and carrying every alias it is known by; an alias names
    /// its entity wherever it is written, whether or not the tagger read it as a name. A group holding a known person is that person.
    nonisolated static func resolvingAliases(
        _ found: [KnowledgeGraphExtractedEntity], in content: String, aliases: StatedAliases, knownPeople: [String],
        knownAgents: [String: String] = [:]
    ) -> [KnowledgeGraphExtractedEntity] {
        guard !aliases.isEmpty else { return found }
        let people = Set(knownPeople.map { $0.lowercased() })
        let contacts = Set(knownAgents.values.map { $0.lowercased() })
        let summary = "Mentioned in memory: \(clip(content, limit: 220))"
        var mentioned = found
        for key in aliases.keys.sorted() where !found.contains(where: { $0.name.lowercased() == key }) {
            guard let entry = aliases[key], knownTermMentioned(entry.alias, in: content) else { continue }
            mentioned.append(KnowledgeGraphExtractedEntity(name: entry.alias, type: entry.type, summary: summary))
        }
        // The group's one type, by the name it keeps, so a mention of that name alone is the same entity too.
        let types = Dictionary(aliases.values.map { ($0.name.lowercased(), $0.type) }, uniquingKeysWith: { first, _ in first })
        var ordered: [KnowledgeGraphExtractedEntity] = []
        for entity in mentioned {
            let name = aliases[entity.name.lowercased()]?.name ?? entity.name
            guard !ordered.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            let known = aliases.values.filter { $0.name.lowercased() == name.lowercased() }.map(\.alias).sorted()
            let type = types[name.lowercased()] ?? (people.contains(name.lowercased()) ? "person"
                : contacts.contains(name.lowercased()) ? "agent" : entity.type)
            ordered.append(KnowledgeGraphExtractedEntity(name: name, type: type, summary: entity.summary, aliases: known))
        }
        return Array(ordered.prefix(24))
    }

    /// The agent's contacts by every name they are written as, each to the contact's own name: its name, its handles, its endpoint's host
    /// as words ("grok-bot" is "grok bot"), and its name's first word when that word is distinctive (one contact's alone, not a known name in
    /// `taken`, not a stopword: "Grok" of "Grok Bot"). A row associated with another contact (`who`) is that contact. `ids` is each
    /// contact's own name (lowercased) to its id as the app names it (`peer:<id>`); a name two contacts share links neither. Read from
    /// `agents/peers.json` once per index pass; no file is no contacts, and an unreadable one stops indexing with its repair.
    nonisolated static func contactNames(peersURL: URL, taken: Set<String>) throws -> (names: [String: String], ids: [String: String]) {
        let data: Data
        do { data = try Data(contentsOf: peersURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return ([:], [:]) }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MemoryStorageError.databaseUnavailable("""
                \(peersURL.path) is not a contact list; repair the agent's contacts before graph indexing.
                """)
        }
        let byID = Dictionary(rows.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        var names: [String: String] = [:]
        var ids: [String: String] = [:]
        var shared: Set<String> = []
        var firstWords: [String: Set<String>] = [:]
        for row in rows {
            let owner = (row["who"] as? String).flatMap { byID[$0] } ?? row
            guard let contact = (owner["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty else { continue }
            if let id = owner["id"] as? String, !id.isEmpty {
                if let known = ids[contact.lowercased()], known != "peer:" + id { shared.insert(contact.lowercased()) }
                ids[contact.lowercased()] = "peer:" + id
            }
            var written = [row["name"] as? String ?? ""] + ((row["handles"] as? [String]) ?? []).filter { !$0.contains(":") }
            if let host = (row["endpoint"] as? String).flatMap(URL.init(string:))?.host?.replacingOccurrences(of: "-", with: " "),
               host.allSatisfy({ $0.isLetter || $0 == " " }) {
                written.append(host)
            }
            for raw in written {
                guard let name = cleanEntityName(raw) else { continue }
                if names[name.lowercased()] == nil { names[name.lowercased()] = contact }
                let words = name.split(separator: " ").map(String.init)
                if words.count > 1, let first = words.first, first.count >= 3, first.allSatisfy(\.isLetter),
                   cleanEntityName(first) != nil {
                    firstWords[first.lowercased(), default: []].insert(contact)
                }
            }
        }
        for (word, owners) in firstWords where owners.count == 1 && names[word] == nil && !taken.contains(word) {
            names[word] = owners.first
        }
        for name in shared { ids[name] = nil }
        return (names, ids)
    }

    private nonisolated static func taggedNames(
        in content: String,
        knownPeople: [String]
    ) -> [(String, String)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = content
        // Short rows may not establish a language. Leave it unknown rather than teaching the tagger an English interpretation without evidence.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(content)
        if let language = recognizer.dominantLanguage {
            tagger.setLanguage(language, range: content.startIndex..<content.endIndex)
        }
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

    /// Known people remain credible even when the tagger's short-row filters reject a proposed name.
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
        // A lowercase interior word usually glues a verb or noun onto a capitalized name.
        if tokens.count > 1,
           tokens.contains(where: { ($0.first?.isLowercase ?? false) && !nameParticles.contains($0.lowercased()) }) {
            return false
        }
        // A leading verb can be glued to a known person's name; a known name followed by a surname stays credible.
        if type == "person", tokens.count > 1,
           let known = lowerKnown.first(where: { tokens.map { $0.lowercased() }.contains($0) }),
           tokens.first?.lowercased() != known {
            return false
        }
        // Acronyms are not organizations merely through capitalization; known terms already have explicit identities.
        if tokens.count == 1, name.count <= 5, name == name.uppercased(),
           name.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return false
        }
        // Acronyms and verb-inflected acronyms do not become organisation names by acquiring a neighbour.
        if tokens.count > 1, tokens.contains(where: isAcronymFragmentToken) {
            return false
        }
        // Occupational titles cannot establish an organization.
        if type == "organization", tokens.count > 1,
           let last = tokens.last?.lowercased(), roleNouns.contains(last) {
            return false
        }
        let before = content[content.startIndex..<range.lowerBound]
        let after = content[range.upperBound..<content.endIndex]
        let prevWord = before.split(whereSeparator: { !$0.isLetter && $0 != "\'" }).last.map { String($0).lowercased() }
        let nextWord = after.split(whereSeparator: { !$0.isLetter }).first.map { String($0).lowercased() }
        // An article before a single capital may indicate a common noun rather than a name.
        if tokens.count == 1, type != "person", let prevWord, ["the", "a", "an"].contains(prevWord) {
            return false
        }
        // Place names used adjectivally do not establish a place entity.
        if type == "place", let nextWord, attributivePlaceFollowers.contains(nextWord) {
            return false
        }
        // Sentence-initial capitalization alone proves no name; require another mid-sentence use.
        if tokens.count == 1, isSentenceInitial(range.lowerBound, in: content) {
            // Sentence subjects suggest people; imperative verbs followed by nouns, pronouns, determiners or adjectives do not.
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

    /// Match dynamic people with the same whole-word, case-insensitive rules as fixed terms.
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

    /// Collapse only persona-document paths to bare filenames; general basename folding would merge unrelated repository files.
    private static func canonicalFileEntityName(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let upper = basename.uppercased()
        return canonicalPersonaDocuments[upper] ?? raw
    }

    /// A short all-caps acronym ("SSH", "VM") or verb-inflected acronym ("SSHes") cannot join a neighbour's name.
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

    /// A kind the name itself states: the words "user" or "assistant", a file's extension, an event word. Any other name is a concept.
    private static func inferType(_ name: String) -> String {
        let lower = name.lowercased()
        if ["user", "the user", "assistant", "the assistant"].contains(lower) {
            return "person"
        }
        if lower.hasSuffix(".md") || lower.hasSuffix(".json") || lower.hasSuffix(".swift")
            || lower.hasSuffix(".app") || lower.hasSuffix(".sqlite") {
            return "tool"
        }
        if lower.contains("launch") || lower.contains("sunday") || lower.contains("rem cycle") {
            return "event"
        }
        return "concept"
    }

    /// Familiar names found even where the tagger misses them; each is typed by its sentence, never by this list.
    private static let knownTerms: [(name: String, pattern: String)] = [
        "NativeAgent", "Claude", "GPT", "Astra", "Gemini", "Kimi", "Grok", "Mistral", "Llama", "DeepSeek", "Swift", "CoreML", "Core ML",
        "Apple", "macOS", "Telegram", "OpenAI", "Anthropic", "TradingView", "APNS", "MCP", "Hermes", "OpenClaw", "ClawDeck",
        "SOUL.md", "VOICE.md", "USER.md", "GROWTH.md", "AGENTS.md",
    ].map { name in
        (name, "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b")
    }

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
        // Bare pronouns cannot become concept entities through any capture path.
        "he", "she", "her", "him", "his", "hers", "they", "them", "their",
        "theirs", "us", "our", "ours", "me", "my", "mine", "these", "those",
        // Whole-phrase stopwords exclude standalone calendar and filler words while allowing names such as "May Lee".
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec",
        "today", "tomorrow", "yesterday", "tonight", "now", "next",
        "last", "first", "finally", "also", "just", "still", "again",
        "remember", "reminder", "update", "updated", "note", "noted",
        "todo", "fyi", "btw",
        // Repetition cannot make common verbs, emphasis adjectives or spelled-out counts standalone named entities.
        "do", "done", "expected", "hard", "nightly", "rewrote",
        "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve",
    ]
}

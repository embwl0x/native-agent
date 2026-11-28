import Foundation
import NaturalLanguage

// Blueprint: | `CognitiveSubstrate+TopicNaming.swift` | `CognitiveSubstrate`: privacy-filtered comparison terms for non-chat felt ambivalence |

extension CognitiveSubstrate {
    static let feltSecretContextWords: Set<String> = [
        "password", "passwd", "passphrase", "token", "tokens", "key", "keys",
        "apikey", "secret", "secrets", "credential", "credentials", "auth",
        "bearer", "oauth", "login", "signin", "ssn", "social", "security",
        "passport", "licence", "license", "card", "cards", "cvv", "cvc", "pin",
        "account", "accounts", "iban", "swift", "routing", "sortcode",
        "wallet", "mnemonic", "seedphrase", "private", "redacted",
        "github", "openai", "anthropic", "stripe", "slack", "google",
    ]
    static let feltSecretContextRadius = 2

    static let feltWeakObjectWords: Set<String> = [
        "chat", "user", "users", "surface", "session", "message", "messages",
        "turn", "turns", "role", "agent", "assistant", "system", "tool",
        "tools", "bridge", "remote", "local", "desktop", "mobile",
        "telegram", "slack", "discord", "imessage", "email", "inbox",
        "mention", "mentions", "mentioned", "tell", "tells", "told", "asks",
        "asked", "said", "says", "know", "knows", "think", "thinks", "want",
        "wants", "need", "needs", "look", "looks", "looking", "make", "makes",
        "made", "take", "takes", "give", "gives", "send", "sends", "keep",
        "keeps", "going", "gonna", "please", "thanks", "thank", "sure",
        "maybe", "right", "okay", "stuff", "something", "anything",
        "broke", "broken", "breaks", "failed", "fails", "failing",
        "works", "worked", "working", "runs", "running", "landed",
        "lands", "shipped", "ships", "uses", "used", "using",
        "happened", "happens", "started", "starts", "stopped", "stops",
        // Duration and counting words cannot name felt objects, independently of summaryStopwords.
        "minute", "minutes", "hour", "hours", "days", "week", "weeks",
        "weekend", "month", "months", "year", "years", "second", "seconds",
        "today", "tonight", "tomorrow", "yesterday", "morning", "afternoon",
        "evening", "night", "nights", "later", "again", "soon", "while",
        "moment", "moments", "time", "times", "ages",
        "first", "third", "fourth", "last", "next", "once", "twice", "half",
        "three", "four", "five", "seven", "eight", "nine",
        // Negations and bare adverbs do not name subjects.
        "never", "always", "really", "actually", "probably", "still",
        "already", "almost", "just", "only", "quite", "rather", "very",
        "enough", "instead", "anyway", "though", "whether", "either",
        "neither", "nothing", "everything",
        // Abstract filler nouns name no subject even when they pass the part-of-speech gate.
        "fact", "facts", "part", "parts", "thing", "things", "point", "points",
        "anyways", "bunch", "kind", "kinds", "sort", "sorts",
        // Bare verbs and contractions are weak; "reading" remains eligible as a noun.
        "read", "reads", "find", "finds", "nailed", "nails",
        "shes", "hes", "theyre", "youre", "thats", "dont", "didnt", "cant",
    ]

    static func feltSafeTokenScan(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var scrubbed = ""
        var depth = 0
        for character in text {
            if character == "[" || character == "(" || character == "<" {
                depth += 1
                scrubbed.append(" ")
            } else if character == "]" || character == ")" || character == ">" {
                depth = max(0, depth - 1)
                scrubbed.append(" ")
            } else if depth == 0 {
                scrubbed.append(character)
            }
        }

        // Whitespace tokens preserve address/pair punctuation needed for neighborhood refusal.
        let rawTokens = scrubbed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return [] }

        var dropped = Set<Int>()
        func dropNeighbourhood(_ index: Int, radius: Int) {
            for offset in -radius...radius {
                let neighbour = index + offset
                if neighbour >= 0, neighbour < rawTokens.count { dropped.insert(neighbour) }
            }
        }

        var words: [String] = []
        for (index, raw) in rawTokens.enumerated() {
            // Addresses, handles, URLs, `key: value` pairs — the token AND what sits beside it, because the neighbour is usually the value.
            if raw.contains("@") || raw.contains("/") || raw.contains(":") || raw.contains("=") {
                dropNeighbourhood(index, radius: 1)
            }
            let word = raw.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted)
            words.append(word)
            if word.isEmpty { dropped.insert(index); continue }
            if word.contains(where: \.isNumber) { dropped.insert(index); continue }
            // Source casing is a privacy boundary; only entirely lowercase terms qualify.
            if word != word.lowercased() { dropped.insert(index); continue }
            if feltSecretContextWords.contains(word) {
                dropNeighbourhood(index, radius: feltSecretContextRadius)
            }
        }

        var tagged = feltWordTagOccurrences(in: scrubbed)
        /// The word's tag in THIS sentence, consumed in order of occurrence. Unknown when the tagger's split and this one disagree about a word.
        func nextTag(_ word: String) -> (known: Bool, tag: NLTag?) {
            guard let first = tagged[word], let head = first.first else { return (false, nil) }
            tagged[word] = Array(first.dropFirst())
            return (true, head)
        }

        var out: [String] = []
        for (index, word) in words.enumerated() {
            guard !dropped.contains(index) else { continue }
            let (known, tag) = nextTag(word)
            guard word.count >= 4,
                  word.allSatisfy(\.isLetter),
                  !summaryStopwords.contains(word),
                  !feltWeakObjectWords.contains(word),
                  !isOpaqueIdentifier(word),
                  !(known && feltTagRefusesAThing(tag)) else { continue }
            out.append(word)
        }
        return out
    }

    static func feltWordTagOccurrences(in text: String) -> [String: [NLTag?]] {
        guard !text.isEmpty else { return [:] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var out: [String: [NLTag?]] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            let word = text[range].lowercased()
            out[word, default: []].append(tag)
            return true
        }
        return out
    }

    static func feltTagRefusesAThing(_ tag: NLTag?) -> Bool {
        switch tag {
        case .adverb?, .pronoun?, .determiner?, .preposition?, .conjunction?,
             .particle?, .interjection?, .number?:
            return true
        default:
            return false
        }
    }

    static func feltSafeObjectTerms(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in feltSafeTokenScan(in: text) {
            guard seen.insert(word).inserted else { continue }
            out.append(word)
            if out.count >= 3 { break }
        }
        return out
    }
}

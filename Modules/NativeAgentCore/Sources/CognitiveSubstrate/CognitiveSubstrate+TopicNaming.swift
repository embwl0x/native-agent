import Foundation
import NaturalLanguage
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+TopicNaming.swift` | `CognitiveSubstrate` topic naming: privacy-filtered noun phrases, producer labels, comparison terms and persisted-label admission for introspection |

extension CognitiveSubstrate {
    // MARK: - Safe object extraction

    /// Words whose NEIGHBOURHOOD is a credential, an identity document, or a
    /// financial instrument. A hit drops the word itself and everything within
    /// `feltSecretContextRadius` tokens either side, because the thing being
    /// named is what must not be rendered: "rotate the anthropic deploy key"
    /// must not surface `anthropic deploy`.
    ///
    /// It also carries the words `TurnTraceRedactor` puts INTO text when it
    /// fires (`[REDACTED_GITHUB_TOKEN]` → github, token, redacted), so a
    /// already-redacted turn cannot re-leak the shape of what was redacted.
    ///
    /// An allowlist would be wrong here and a denylist is right, which is the
    /// reverse of design law 8 — deliberately. Law 8 governs whether a SIGNAL
    /// is admitted; this governs whether TEXT is emitted, and for text the
    /// conservative direction is to drop on suspicion. The cost of a false
    /// positive is no object on one turn. The cost of a false negative is the
    /// user's secret in the model's context.
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

    /// Route names, speech acts and fillers do not name the thing a feeling is about.
    static let feltWeakObjectWords: Set<String> = [
        // route
        "chat", "user", "users", "surface", "session", "message", "messages",
        "turn", "turns", "role", "agent", "assistant", "system", "tool",
        "tools", "bridge", "remote", "local", "desktop", "mobile",
        "telegram", "slack", "discord", "imessage", "email", "inbox",
        // speech acts and fillers
        "mention", "mentions", "mentioned", "tell", "tells", "told", "asks",
        "asked", "said", "says", "know", "knows", "think", "thinks", "want",
        "wants", "need", "needs", "look", "looks", "looking", "make", "makes",
        "made", "take", "takes", "give", "gives", "send", "sends", "keep",
        "keeps", "going", "gonna", "please", "thanks", "thank", "sure",
        "maybe", "right", "okay", "stuff", "something", "anything",
        // State-change verbs do not name a subject; a two-word label must name one thing.
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

    /// Safe tokens retain source positions so only adjacent words can form a rendered phrase.
    /// Bracketed runs, address/pair neighborhoods, digits, non-lowercase tokens and secret neighborhoods are refused.
    /// Remaining terms share stopword, minimum-length and opaque-id rules, then reject weak object words.
    struct FeltSafeToken: Sendable, Equatable {
        var index: Int
        var word: String
        /// Whether this word can be the WHOLE subject on its own. A word is
        /// welcome in the modifier slot of a compound on much weaker terms than
        /// it is welcome standing alone, so the two questions are answered once,
        /// here, from the one in-context tag — never re-asked of a bare word,
        /// which the tagger cannot read ("audit" bare is unclassified, "boundary"
        /// bare is an adjective, and both are nouns in a sentence).
        var standsAlone: Bool = true
    }

    /// The shared scan. Both the term list (used as a comparison key) and the
    /// rendered phrase come from this one walk, so there is no second copy of
    /// the privacy rules to drift.
    static func feltSafeTokenScan(in text: String) -> [FeltSafeToken] {
        guard !text.isEmpty else { return [] }

        // 1. Cut bracketed runs whole.
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

        // 2. Split into raw tokens on whitespace, so a token still carries the
        //    punctuation that identifies it as an address or a pair.
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
            // Addresses, handles, URLs, `key: value` pairs — the token AND what
            // sits beside it, because the neighbour is usually the value.
            if raw.contains("@") || raw.contains("/") || raw.contains(":") || raw.contains("=") {
                dropNeighbourhood(index, radius: 1)
            }
            // Trim surrounding punctuation but keep the token's own letters.
            let word = raw.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted)
            words.append(word)
            if word.isEmpty { dropped.insert(index); continue }
            if word.contains(where: \.isNumber) { dropped.insert(index); continue }
            // Reject anything not entirely lowercase in the source.
            if word != word.lowercased() { dropped.insert(index); continue }
            if feltSecretContextWords.contains(word) {
                dropNeighbourhood(index, radius: feltSecretContextRadius)
            }
        }

        // Felt object candidates are tagged in sentence context to distinguish nouns from verbs and adverbs.
        var tagged = feltWordTagOccurrences(in: scrubbed)
        /// The word's tag in THIS sentence, consumed in order of occurrence.
        /// Unknown when the tagger's split and this one disagree about a word.
        func nextTag(_ word: String) -> (known: Bool, tag: NLTag?) {
            guard let first = tagged[word], let head = first.first else { return (false, nil) }
            tagged[word] = Array(first.dropFirst())
            return (true, head)
        }

        var out: [FeltSafeToken] = []
        for (index, word) in words.enumerated() {
            guard !dropped.contains(index) else { continue }
            let (known, tag) = nextTag(word)
            guard word.count >= 4,
                  word.allSatisfy(\.isLetter),
                  !summaryStopwords.contains(word),
                  !feltWeakObjectWords.contains(word),
                  !isOpaqueIdentifier(word),
                  !(known && feltTagRefusesAThing(tag)) else { continue }
            out.append(FeltSafeToken(
                index: index,
                word: word,
                // A word the tagger never saw keeps the file's standing rule —
                // unknown is kept — and so may still stand alone.
                standsAlone: !known || feltTagNamesAThingAlone(tag)))
        }
        return out
    }

    /// Subject labels exclude verbs, adverbs, adjectives and function words; unknown vocabulary stays eligible in context.
    /// Tag occurrences are keyed by lowercased word so whitespace-based callers can consume them in order.
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

    /// Standalone labels also refuse verbs and adjectives; modifiers and unknown vocabulary remain eligible.
    static func feltTagNamesAThingAlone(_ tag: NLTag?) -> Bool {
        if feltTagRefusesAThing(tag) { return false }
        switch tag {
        case .verb?, .adjective?: return false
        default: return true
        }
    }

    /// Function words and adverbs never name a thing; unknown vocabulary stays eligible in context.
    /// Verbs and adjectives may modify a compound, while known weak verbs are refused by the weak-word set.
    static func feltTagRefusesAThing(_ tag: NLTag?) -> Bool {
        switch tag {
        case .adverb?, .pronoun?, .determiner?, .preposition?, .conjunction?,
             .particle?, .interjection?, .number?:
            return true
        default:
            return false
        }
    }

    /// Persisted single-word labels must name a thing alone; the node's sentence can vouch for an unknown lexicon word.
    static func feltWordNamesAThingAlone(_ word: String, vouchedBy sentence: String? = nil) -> Bool {
        guard !word.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = word
        let tag = tagger.tag(at: word.startIndex, unit: .word, scheme: .lexicalClass).0
        // Unknown standalone tokens are refused; the node's sentence can still establish their role in context.
        guard let tag else { return false }
        if tag == .otherWord {
            return feltSentenceVouchesForWord(word, in: sentence ?? "")
        }
        return feltTagNamesAThingAlone(tag)
    }

    /// The sentence-level second opinion, asked only of a bare `otherWord`.
    /// Walks the node's own words for THIS exact token and takes the tag the
    /// tagger gives that occurrence, where the surrounding sentence is
    /// available to disambiguate it. Only a class that names a thing standing
    /// alone counts; `otherWord` in context is still no answer.
    static func feltSentenceVouchesForWord(_ word: String, in sentence: String) -> Bool {
        guard !word.isEmpty, !sentence.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        var vouched = false
        tagger.enumerateTags(
            in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            guard sentence[range].caseInsensitiveCompare(word) == .orderedSame else { return true }
            if let tag, tag != .otherWord, feltTagNamesAThingAlone(tag) {
                vouched = true
                return false
            }
            return true
        }
        return vouched
    }

    static func feltWordNamesAThing(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = word
        let tag = tagger.tag(at: word.startIndex, unit: .word, scheme: .lexicalClass).0
        return !feltTagRefusesAThing(tag)
    }

    /// The safe topical terms, deduped, in source order. This is the COMPARISON
    /// form — `feltAboutnessKey` normalizes with it — and is deliberately not
    /// what gets rendered; see `feltSafeObjectPhrase` for that.
    static func feltSafeObjectTerms(in text: String, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for token in feltSafeTokenScan(in: text) {
            guard seen.insert(token.word).inserted else { continue }
            out.append(token.word)
            if out.count >= limit { break }
        }
        return out
    }

    /// Renders the first nameable term or adjacent noun phrase, never more than two words.
    static func feltSafeObjectPhrase(in text: String, maxCharacters: Int) -> String? {
        let tokens = feltSafeTokenScan(in: text)
        // Scan every position for an adjacent noun phrase, then a single noun; a leading non-noun does not end the search.
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if index + 1 < tokens.count {
                let next = tokens[index + 1]
                // Neither the sentence nor the two-word fragment always
                // disambiguates a head correctly (NLTagger calls "pull" a
                // noun in both "readings pull" and its full sentence). Keep
                // the existing standalone non-name refusal as a cross-check;
                // unknown vocabulary and adjective modifiers remain welcome.
                if next.index == token.index + 1, token.word != next.word,
                   next.standsAlone, feltWordNamesAThing(next.word) {
                    let pair = "\(token.word) \(next.word)"
                    if pair.count <= maxCharacters, feltPhraseHeadNamesAThing(pair) { return pair }
                }
            }
            // ONE WORD HAS TO BE A NAME BY ITSELF. With no modifier to head, an
            // adjective or a verb in this slot is a fragment wearing a
            // subject's clothes, so it yields to the next candidate instead.
            if token.standsAlone, token.word.count <= maxCharacters { return token.word }
            index += 1
        }
        // Nil is the answer every caller already handles: a sentence with no
        // nameable thing in it gets no object.
        return nil
    }

    /// True when the LAST word of `phrase`, tagged inside that phrase, can head
    /// a noun phrase. Tagged in the phrase rather than bare because the
    /// modifier is what disambiguates the head ("deploy pipeline").
    static func feltPhraseHeadNamesAThing(_ phrase: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = phrase
        var headTag: NLTag?
        tagger.enumerateTags(
            in: phrase.startIndex..<phrase.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            headTag = tag
            return true
        }
        // Verbs and adverbs cannot head a name; everything the tagger refuses
        // outright cannot either. Unknown stays kept, as everywhere else here.
        if headTag == .verb { return false }
        return !feltTagRefusesAThing(headTag)
    }

    // MARK: - The topic label a conversation turn can honestly carry

    /// Producers persist a payload-free topic label before minting the node; no safe noun phrase means no label.
    public static func feltTopicLabel(
        from text: String,
        maxCharacters: Int = 32
    ) -> String? {
        // Over-length is a REFUSAL, not a trim: truncating mid-word would
        // manufacture a fragment she would read as the name of a thing — the
        // same refusal `feltObjectLabel` makes.
        return feltSafeObjectPhrase(in: text, maxCharacters: maxCharacters)
    }

    /// Payload-free subject labels use a usable label or content noun phrase, never a subject ID or channel type.
    static func innerStateSubjectLabel(_ node: CognitiveNode) -> String? {
        let label = (node.subjectReference.label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Stored labels must name a thing; otherwise derive the subject from the node's own words.
        if !label.isEmpty, feltLabelNamesAThing(label, vouchedBy: node.summary) {
            return String(label.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
        }
        return feltSafeObjectPhrase(
            in: node.summary,
            maxCharacters: CognitiveInnerStateReading.subjectLabelCharacters)
    }

    /// True when at least one word of a persisted subject label names a thing.
    /// The same two tests the producer applies, over a label rather than a
    /// candidate token, so the two seams cannot disagree.
    static func feltLabelNamesAThing(_ label: String, vouchedBy sentence: String? = nil) -> Bool {
        // Preserve original casing for tagging; only the lowercase weak-word set uses folded words.
        let words = label
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        // Standalone labels require a nameable subject; rejected labels defer to the node's words.
        if words.count == 1, let only = words.first {
            return !feltWeakObjectWords.contains(only.lowercased())
                && feltWordNamesAThingAlone(only, vouchedBy: sentence)
        }
        // Stored phrases obey the producer's noun-phrase head rule.
        guard feltPhraseHeadNamesAThing(label) else { return false }
        return words.enumerated().contains { index, word in
            guard !feltWeakObjectWords.contains(word.lowercased()) else { return false }
            // A capitalised word that is NOT the label's first carries no
            // sentence-initial excuse for its capital: it is a proper name,
            // whatever the lexicon makes of the lowercase homograph.
            if index > 0, word.first?.isUppercase == true { return true }
            return feltWordNamesAThing(word)
        }
    }
}

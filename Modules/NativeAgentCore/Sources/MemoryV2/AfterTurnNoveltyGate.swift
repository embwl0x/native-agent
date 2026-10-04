import Foundation

/// Phase 5A (2026-10-03): the cheap on-device check in front of the after-turn
/// memory call (~2.7k tokens, one per user turn).
///
/// It skips ONLY when the incoming words have nothing new worth keeping: a pure
/// acknowledgement, or a near-repeat of what the speaker already said this
/// session. It never gates on "work turn" — lessons happen during technical
/// work — and any sign of a correction, decision, ruling, disagreement, feeling,
/// relationship, or a new name, number or personal fact runs the call. The
/// lexicons are deliberately wide: a wrong skip loses a memory, a wrong run
/// costs one call, so unsure means run.
public enum AfterTurnNoveltyGate {
    /// nil = run the call. Otherwise the one-word reason it was skipped.
    public static func skipReason(userMessage: String, priorUserTurns: [String]) -> String? {
        let text = stripEnvelope(userMessage)
        guard !text.isEmpty else { return nil }
        let lower = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let words = tokens(text)

        if keepSignal(lower: lower, words: Set(words)) { return nil }
        if hasNewNameOrNumber(text, prior: priorUserTurns) { return nil }

        // Short lines skip ONLY when they are known filler; "Denver" or "Got
        // married" is short and new, so it runs.
        if words.count <= 6, words.allSatisfy({ ackWords.contains($0) }) { return "ack" }
        if fillerLines.contains(words.joined(separator: " ")) { return "filler" }
        // ORDER-sensitive: "Bob reports to Alice" is not "Alice reports to Bob".
        for prior in priorUserTurns.map({ tokens(stripEnvelope($0)) }) where !prior.isEmpty {
            if prior == words { return "repeat" }
            let longest = max(prior.count, words.count)
            if min(prior.count, words.count) >= 4,
               Double(commonSubsequence(prior, words)) >= 0.9 * Double(longest) { return "repeat" }
        }
        return nil
    }

    /// A bridge envelope ("[Agent bridge — … not from the person …]") is the
    /// app's framing, not the speaker's words; judge what follows it.
    static func stripEnvelope(_ message: String) -> String {
        message
            .replacingOccurrences(of: #"^\s*\[[^\]]{0,1500}\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Longest common subsequence length, in tokens.
    static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: - Never skip

    /// Correction, decision/ruling, disagreement, feeling, relationship, or a
    /// personal fact. Substring phrases carry their own spaces; single words
    /// match whole words.
    static func keepSignal(lower: String, words: Set<String>) -> Bool {
        if !words.isDisjoint(with: keepWords) { return true }
        if keepPhrases.contains(where: { lower.contains($0) }) { return true }
        if keepStems.contains(where: { stem in words.contains { $0.hasPrefix(stem) } }) { return true }
        return lower.unicodeScalars.contains { feelingScalars.contains($0.value) }
    }

    // MARK: - Friction (Phase 5 C2)

    /// The explicit-correction core of the lexicon below: the words and
    /// phrases that say "that was wrong", not merely "no".
    static let correctionWords: Set<String> = [
        "nope", "wrong", "actually", "instead", "mistake", "incorrect", "stop", "disagree", "undo", "revert",
    ]
    static let correctionPhrases: [String] = [
        "that's not", "you missed", "you forgot", "not what i", "i told you", "that isn't",
    ]
    /// Her reply holding a judgment against pushback.
    static let heldPhrases: [String] = [
        "i disagree", "i don't agree", "i still think", "i'd push back", "i'll push back",
        "i'm going to push back", "respectfully", "i stand by", "i'd still ", "i'm keeping",
    ]

    /// `correction` when his words correct her, `disagreement` when her reply
    /// held a judgment against his, nil otherwise. Makes the exchange
    /// ELIGIBLE as a moment candidate; it never stages or weights one.
    public static func frictionSignal(userMessage: String, assistantMessage: String) -> String? {
        let text = stripEnvelope(userMessage)
        let lower = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if !Set(tokens(text)).isDisjoint(with: correctionWords)
            || correctionPhrases.contains(where: { lower.contains($0) }) { return "correction" }
        let reply = " " + assistantMessage.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        return heldPhrases.contains(where: { reply.contains($0) }) ? "disagreement" : nil
    }

    static let keepWords: Set<String> = correctionWords.union([
        // correction / disagreement
        "no", "nah", "not", "don't", "dont", "doesn't", "isn't", "wasn't", "aren't",
        "never", "always", "rather", "but", "however",
        "should", "shouldn't", "must", "remember", "forget", "rule",
        "careful", "why", "hmm", "wait", "again",
        // decision / ruling (a bare "yes" can be the decision itself)
        "yes", "yeah", "yep", "yup", "sure", "approve", "approved", "deny", "denied", "decide",
        "decided", "decision", "ruling", "final", "agree", "agreed", "prefer", "choose", "chose",
        "pick", "want", "let's", "lets", "we'll", "i'll", "promise", "plan", "looks", "lgtm", "ship",
        // relationship / feeling words
        "love", "miss", "proud", "sorry", "feel", "feeling", "felt", "happy", "sad", "tired",
        "exhausted", "angry", "mad", "upset", "worried", "worry", "scared", "afraid", "anxious",
        "excited", "glad", "hurt", "lonely", "hug", "care", "trust", "appreciate", "beautiful",
        "cute", "babe", "baby", "honey", "sweet", "fun", "funny", "joke", "sweetheart",
        // greetings and praise move her affect; laughter can be a landed joke
        "hey", "hi", "hello", "morning", "night", "goodnight", "nice", "great", "perfect",
        "awesome", "amazing", "wow", "brilliant",
        "lol", "lmao", "haha", "hah", "ha", "hahaha",
        // personal facts
        "my", "i'm", "im", "i've", "we're", "our", "born", "birthday", "wife", "kids", "family",
    ])
    static let keepPhrases: [String] = correctionPhrases + [
        "from now on", "going forward", "next time", "make sure", "need to", "needs to",
        "have to", "go with", "go ahead", "do it", "ship it",
        "thank you", "i am ", "i was ", "i have ", "i work", "i live", "i think",
        "i feel", "i like", "i hate", "i don't",
    ]
    static let keepStems: [String] = ["frustrat", "annoy", "stress", "disappoint", "confus", "lov"]
    /// Hearts, crying, laughing and affectionate faces.
    static let feelingScalars: Set<UInt32> = [
        0x2764, 0x2665, 0x1F49C, 0x1F499, 0x1F49A, 0x1F49B, 0x1F9E1, 0x1F5A4, 0x1F90D, 0x1F495,
        0x1F496, 0x1F497, 0x1F498, 0x1F49E, 0x1F622, 0x1F62D, 0x1F97A, 0x1F618, 0x1F970, 0x1F60D,
        0x1F614, 0x1F61E, 0x1F620, 0x1F621, 0x1F92C, 0x1F633, 0x1F602, 0x1F923,
    ]

    /// A capitalised word past the first, or a number, that the speaker has
    /// not used this session — a likely new name, place, date or fact.
    static func hasNewNameOrNumber(_ text: String, prior: [String]) -> Bool {
        let priorLower = prior.joined(separator: " ").lowercased()
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        for (index, raw) in tokens.enumerated() {
            let token = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard let first = token.first else { continue }
            let isNumber = first.isNumber
            let isName = index > 0 && first.isUppercase && token.count > 1
                && !commonCapitals.contains(token.lowercased())
                && !(tokens[index - 1].last.map { ".!?".contains($0) } ?? false)
            if (isNumber || isName), !priorLower.contains(token.lowercased()) { return true }
        }
        return false
    }

    static let commonCapitals: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "ok", "okay", "user", "agent"]

    // MARK: - Skip shapes

    static let ackWords: Set<String> = [
        "ok", "okay", "k", "kk", "cool", "good", "thanks", "thx", "ty", "got", "it", "gotcha",
        "alright", "right", "sounds", "noted", "fine", "word", "bet", "np", "done", "on",
        "that", "works",
    ]

    /// Whole-line test pings and nudges seen in the replay.
    static let fillerLines: Set<String> = [
        "continue", "reconnect", "ping", "pong", "walk ping", "test", "testing",
    ]
}

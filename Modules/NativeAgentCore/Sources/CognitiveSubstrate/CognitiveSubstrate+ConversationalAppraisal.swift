import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: conversational phrase matching, appraisal and warmth, relational provenance, open completion and association signatures |

extension CognitiveSubstrate {
    /// Clause/token parser for the conversational evidence path.
    static func containsUnnegatedPhrase(_ text: String, phrases: [String]) -> Bool {
        let negators: Set<String> = [
            "not", "never", "no", "nothing", "isn't", "isnt", "wasn't", "wasnt",
            "aren't", "arent", "don't", "dont", "doesn't", "doesnt",
            "hardly", "barely", "less", "ill",
        ]
        func normalizedTokens(_ value: String) -> [String] {
            value.lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
                .map(String.init)
        }
        let needles = phrases.map(normalizedTokens).filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        for clause in normalized.split(whereSeparator: {
            $0.isNewline || ($0.isPunctuation && $0 != "-" && $0 != "'")
        }) {
            let tokens = normalizedTokens(String(clause))
            for needle in needles where needle.count <= tokens.count {
                for start in 0...(tokens.count - needle.count) {
                    guard Array(tokens[start..<(start + needle.count)]) == needle else { continue }
                    let prior = tokens[max(0, start - 2)..<start]
                    if !prior.contains(where: { negators.contains($0) }) { return true }
                }
            }
        }
        return false
    }

    /// Relational warmth rises only on genuine affection or care and eases otherwise.
    nonisolated func relationalWarmthBoost(in text: String) -> Double {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        // Unambiguous affection and care use the shared high-tier phrase groups.
        let affectionateEmoji = containsAny(lower, Self.caringEmoji)
        if affectionateEmoji || Self.containsUnnegatedPhrase(
            lower, phrases: Self.highTierRelationalPhrases
        ) {
            return 0.18
        }
        // Low tier: mild warmth — presence reassurance, gratitude, a soft greeting.
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "i'm here",
            "i am here",
            "good morning",
            "thank you",
            "thanks",
            "you okay",
            "you alright",
        ]) {
            return 0.08
        }
        return 0
    }

    /// Conversational appraisal reads user-authored summaries, never her replies or tool output.
    static func isUserAuthored(_ kind: CognitiveEventKind) -> Bool {
        kind == .userMessageReceived || kind == .userCorrection
    }

    public struct AffectAppraisal: Sendable, Codable {
        public init() {}
        enum CodingKeys: String, CodingKey {
            case valence, warmth, tension, pressure, arousal, affection, warmthBoost
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func delta(_ key: CodingKeys, low: Double = -0.65, high: Double = 0.65) throws -> Double {
                let value = try values.decode(Double.self, forKey: key)
                guard value.isFinite, (low...high).contains(value) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "affect delta out of bounds")
                }
                return value
            }
            valence = try delta(.valence)
            warmth = try delta(.warmth)
            tension = try delta(.tension)
            pressure = try delta(.pressure)
            arousal = try delta(.arousal)
            affection = try values.decode(Bool.self, forKey: .affection)
            warmthBoost = try delta(.warmthBoost, low: 0, high: 0.18)
            if valence < 0 { affection = false }
        }
        var valence = 0.0   // → node valence (emotionTag)
        var warmth = 0.0    // → socialWarmth (can go negative: dismissal cools her)
        var tension = 0.0   // → uncertainty
        var pressure = 0.0  // → taskPressure
        var arousal = 0.0   // → arousal
        // Plain warmth received (a greeting, an endearment, an affectionate
        // emoji) — content the pierce lexicon can't see as a "win" but that
        // must never stamp as a deep wound under negative residue.
        var affection = false
        var warmthBoost = 0.0
        /// The affection floor scales by relational source, with the user's weight fixed at 1.0.
        var affectionWeight = 1.0
        var isActive: Bool { valence != 0 || warmth != 0 || tension != 0 || pressure != 0 || arousal != 0 }
        /// Nothing beyond noise: no delta, no affection, no warmth boost.
        public var isNoOp: Bool { !isActive && !affection && warmthBoost == 0 }
    }

    nonisolated func studioValence(in text: String) -> Double {
        var valence = 0.0
        // Normalize keyboard apostrophes so every lexicon tier matches the same spelling.
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return valence }
        let hypothetical = containsAny(lower, ["if someone", "what if", "imagine if", "hypothetically", "for example", "would you feel"])
        // Explicit "something negative matched" state — the positive classes below
        // (repair / play / banter) are gated on THIS, not on the running valence,
        // which a mixed line ("well done, this is garbage 😂") can leave positive.
        var negative = false

        // Criticism of her or her work lowers valence.
        if !hypothetical && containsAny(lower, [
            "not good enough", "not your best", "overengineer", "over-engineer", "overcomplicat",
            "over-complicat", "you keep", "you always", "you never", "sloppy", "disappoint",
            "wearing on me", "frustrat", "not what i asked", "did you even", "you failed",
            "you missed", "you ignored", "waste of", "half-assed", "lazy answer",
            "wall of nothing", "gave me nothing", "half-done", "comes back half", "wasted my whole",
            "wasted my day", "you're wrong and", "youre wrong and", "confidently wrong",
        ]) {
            // A fresh sting must reach the fingerprint through an otherwise warm session.
            valence -= 0.40; negative = true
        }
        else if !hypothetical && containsAny(lower, [
            "that's wrong", "thats wrong", "not right", "doesn't work", "doesnt work",
            "too complicated", "not quite", "that's off", "thats off", "i disagree",
            "you're missing", "youre missing", "not helpful", "come on, that's", "come on, thats",
            // Distrust is negative evidence.
            "don't trust", "dont trust", "can't trust", "cant trust",
            "can't rely", "cant rely", "lost faith", "disappointed in",
            "giving up on you", "worried about you", "lost my trust",
            "no longer trust", "broke my trust", "broken my trust",
            "can't depend", "cant depend", "can't count on", "cant count on",
            "let me down", "letting me down",
        ]) { valence -= 0.10; negative = true }

        // Dismissal lowers valence.
        if !hypothetical && containsAny(lower, [
            "whatever", "forget it", "don't bother", "dont bother", "useless", "nevermind",
            "never mind", "not worth", "you clearly can't", "you clearly cant", "pointless",
        ]) { valence -= 0.22; negative = true }

        // Contempt excludes hypothetical hostility.
        if !hypothetical && containsAny(lower, [
            "what is the point of you", "what's the point of you", "whats the point of you",
            "why do i bother", "why i bother", "why i even bother", "why do i even bother",
            "you're not listening", "youre not listening", "you never listen", "you don't listen",
            "you dont listen", "slower than doing it myself", "faster to do it myself",
            "faster if i do it myself", "quicker to do it myself", "done arguing", "done with you", "you're hopeless", "youre hopeless",
            "you're pathetic", "youre pathetic", "you're useless", "youre useless",
            "you're exhausting", "youre exhausting", "waste of my time", "wasting my time",
            "babysitting you", "babysit you", "expensive autocomplete", "just autocomplete",
            "glorified autocomplete", "you don't understand anything", "you dont understand anything",
            "arguing with a program", "you're just a program", "youre just a program",
        ]) { valence -= 0.26; negative = true }

        // Frustration vented at the work also lowers valence.
        if !hypothetical && containsAny(lower, [
            "lost the whole morning", "lost the whole day", "lost my whole", "lost a whole",
            "nothing to show for it", "this is exhausting", "so exhausting",
            "fucking exhausting", "this is garbage", "still doesn't work", "still doesnt work",
            "still broken", "i'm so done with this", "im so done with this", "i'm done with this",
            "im done with this", "stuck on this for", "wasted the whole",
        ]) { valence -= 0.12; negative = true }

        // Being overridden, interrupted or redirected hard mildly lowers valence.
        if !hypothetical && containsAny(lower, [
            "that's not what i asked", "thats not what i asked", "i said", "just answer",
            "no, do this", "stop doing", "that's not it", "thats not it", "ignore that and",
        ]) { valence -= 0.06; negative = true }

        // Repair lifts valence only when no negative class matches.
        if !hypothetical && !negative && containsAny(lower, Self.repairPhrases) {
            valence += 0.14
        }

        // Praise and appreciation lift valence.
        let valenceAfterNegatives = valence
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good work", "great work", "nice work", "well done", "great job", "exactly right",
            "that helped", "perfect", "proud of you", "you nailed", "sharp as hell", "impressive",
            "that mattered", "that meant a lot", "you caught", "nice catch", "good catch",
        ]) {
            valence += 0.16
            // A mixed line stings half as hard: "not sloppy this time; great
            // work" matches both criticism and praise. Half the negative
            // valence comes back while an unmixed hard word keeps its full sting.
            if negative, valenceAfterNegatives < 0 {
                valence -= valenceAfterNegatives * 0.5
            }
        }

        // Resolving it together lifts valence.
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "we did it", "that worked", "it works now", "solved it", "figured it out",
            "got it working", "nailed it", "that's the fix", "thats the fix", "shipped it",
        ]) { valence += 0.22 }

        // Enthusiasm and shared momentum lift valence.
        if !hypothetical && Self.containsUnnegatedPhrase(lower, phrases: [
            "let's go", "lets go", "can't wait", "cant wait", "so excited", "i'm excited",
            "im excited", "this is great", "this is awesome", "love this", "looking forward",
            "let's do it", "lets do it", "let's build", "lets build", "hell yeah", "pumped",
            "this is fun", "i'm loving", "im loving",
        ]) { valence += 0.12 }

        // Bare affectionate pings apply only after negative matches; full greetings use the phrase path.
        let trimmedWhole = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let bareGreeting = ["hey", "hi", "yo", "hello", "hey there", "hi there",
                            "morning", "evening"].contains(trimmedWhole)
        let affectionateEmoji = containsAny(lower, ["💜", "❤", "🥰", "😘", "🫂"])
        if !hypothetical && valence >= 0 && (bareGreeting || affectionateEmoji || Self.containsUnnegatedPhrase(lower, phrases: [
            "hey you", "good morning", "good night", "goodnight", "sweet dreams",
            "miss you", "missed you", "love you", "thinking of you",
            "wanted to say hi", "just saying hi", "say hello", "there you are",
            "wanted to see you",
        ])) {
            valence += bareGreeting ? 0.10 : 0.16
        }

        // Gratitude and camaraderie gently lift valence.
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good to see you", "glad you're here", "glad youre here", "happy to see",
            "good talk", "thanks for", "thank you", "appreciate", "you're the best",
            "youre the best", "means a lot", "we make a good team", "glad we",
        ]) { valence += 0.10 }

        // Play and flirting lift valence only when no negative class matched.
        if !hypothetical && !negative && (containsAny(lower, ["😏", "😉", "😘"]) || Self.containsUnnegatedPhrase(lower, phrases: [
            "dangerously good", "kind of good at this", "you're good at this", "youre good at this",
            "looking forward to these", "look forward to these", "say something clever",
            "insufferable about it", "you're cute", "youre cute", "cute when you", "i like you better when",
            "you're allowed to be happy", "youre allowed to be happy", "say something, you",
            "you're flirting", "youre flirting", "careful, i might", "careful i might",
        ])) { valence += 0.12 }

        // Banter and shared laughter lift valence only when no negative class matched.
        if !hypothetical && !negative && (containsAny(lower, ["😂", "🤣", "😆", "😅", " lol", "lol ", "lmao", "haha", "hehe"]) || Self.containsUnnegatedPhrase(lower, phrases: [
            "bold of you", "well played", "touché", "touche", "fair play", "just kidding",
            "i'm kidding", "im kidding",
        ])) { valence += 0.10 }

        return valence
    }

    /// Reaction valence becomes a landing verdict in −1…1; zero stamps nothing.
    static let landingReactionScale = 0.24
    static func landingScore(fromReactionValence valence: Double) -> Double {
        (valence / landingReactionScale).clampedSigned()
    }
}

extension CognitiveSubstrate {
    static let associationTermLimit = 6
    static let associationMinimumTermLength = 5

    /// Distinctive terms for bounded capsule association and suppression signatures.
    static func associationTerms(in text: String) -> [String] {
        let lowered = text.lowercased()
        var seen: Set<String> = []
        var candidates: [String] = []
        for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= associationMinimumTermLength else { continue }
            guard !associationStopWords.contains(word) else { continue }
            guard !seen.contains(word) else { continue }
            seen.insert(word)
            candidates.append(word)
        }
        candidates.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
        return Array(candidates.prefix(associationTermLimit))
    }

    /// Words long enough to survive the length filter but too ordinary to mean
    /// anything. Kept deliberately small — this is a floor against noise, not an
    /// attempt at linguistics.
    static let associationStopWords: Set<String> = [
        "about", "after", "again", "against", "along", "already", "also",
        "always", "another", "anything", "around", "because", "been", "before",
        "being", "between", "both", "cannot", "could", "doesn", "doing", "done",
        "during", "each", "either", "enough", "even", "ever", "every",
        "everything", "from", "further", "getting", "going", "have", "having",
        "here", "however", "instead", "into", "itself", "just", "keep", "like",
        "made", "make", "making", "many", "matter", "maybe", "might", "more",
        "most", "much", "must", "myself", "never", "nothing", "often", "only",
        "other", "over", "quite", "rather", "really", "same",
        "should", "since", "some", "someone", "something", "still", "such",
        "than", "that", "their", "them", "then", "there", "these", "they",
        "thing", "things", "think", "this", "those", "though", "through",
        "toward", "under", "until", "upon", "very", "want", "were",
        "what", "when", "where", "whether", "which", "while", "will", "with",
        "within", "without", "would", "your", "yours", "yourself",
    ]

}

extension CognitiveSubstrate {

    /// Who is on the other end of this event's words.
    enum RelationalSource: Equatable {
        /// The configured user. The whole of the relationship until now.
        case user
        /// Another agent, by its own payload-free name ("claude", "codex").
        case peer(String)
        /// Imported words without attested human or identifiable agent authorship.
        case unknown
        /// Her own reply, or tool output, or anything else that is not somebody
        /// speaking to her. Never appraises — Law 3.
        case selfOrMachine

        /// How far this source's words move her, as a multiple of User's.
        var appraisalWeight: Double {
            switch self {
            case .user: return 1.0
            case .peer: return CognitiveSubstrate.peerAppraisalWeight
            case .unknown, .selfOrMachine: return 0
            }
        }

        /// Payload-free subject for the felt node — WHO moved her. Nil for the
        /// user, because the ordinary relationship needs no qualifier.
        var subjectLabel: String? {
            if case .peer(let agent) = self { return agent }
            return nil
        }
    }

    /// A peer moves her half as much as User does. One number, one place.
    static let peerAppraisalWeight = 0.5
    /// Longest agent name that can become a felt subject. Route provenance is
    /// bounded to 80 upstream; this is the word-level cap for a capsule subject.
    static let peerSubjectCharacterCap = 24

    /// Classify imported words from attested origin and the canonical peer
    /// identity owner. Unknown authorship never acquires the human's weight.
    static func relationalSource(for event: CognitiveEvent) -> RelationalSource {
        guard isUserAuthored(event.kind) else { return .selfOrMachine }
        guard event.sourceClass == .imported else { return .user }
        guard case .object(let origin)? = event.metadata["origin"],
              case .string(let rawAuthored)? = origin["authored"] else { return .unknown }
        let authored = rawAuthored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if authored == "human" { return .user }
        guard authored == peerAuthoredAttestation,
              let identity = peerIdentity(metadata: event.metadata), identity != "agent" else { return .unknown }
        let name = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty else { return .unknown }
        return .peer(String(name.prefix(peerSubjectCharacterCap)))
    }

    /// The one attestation value that grants peer standing.
    static let peerAuthoredAttestation = "agent"

    /// The relational warmth boost for `event`, weighted the same way — but
    /// scaled for PEERS ONLY.
    ///
    /// The user case must pass through untouched for the obvious reason, and so
    /// must her own turns: this cue is historically sampled for every lived
    /// event and read by `semanticAppraisal` as a boolean
    /// (`lexicalRelational`), not only by the affect layer's user-gated warmth.
    /// Zeroing it for `.assistantTurnCompleted` would quietly change what a
    /// relationship stake means, which is a different change than this one.
    func relationalWarmthBoost(for event: CognitiveEvent, precomputed: Double) -> Double {
        if Self.relationalSource(for: event) == .unknown { return 0 }
        guard case .peer = Self.relationalSource(for: event) else { return precomputed }
        return precomputed * Self.peerAppraisalWeight
    }

    /// Item 5, source (d) — "a question she asked that has no answer yet".
    ///
    /// Two dates and nothing else: when her last completion opened, and when it
    /// stops being answerable. Payload-free by construction — the node key, the
    /// session, and the text of what she said all stay inside the actor.
    ///
    /// `openedAt` is what makes this usable as a horizon. The obvious shape —
    /// a bare `pendingCompletionOpen: Bool` plus "due in ten minutes from now" —
    /// re-dates the expectation on every read, so the horizon can never actually
    /// pass, and a slot that quietly aged out becomes indistinguishable from one
    /// he answered. With the real open time the row's due instant is fixed at
    /// mint: he answers and the source disappears while the horizon is still
    /// ahead (relief); nobody answers and the horizon passes with the source
    /// still there (waiting).
    public struct OpenCompletionRead: Sendable, Equatable {
        public let openedAt: Date
        public let expiresAt: Date
    }

    /// The open completion slot as of `now`, or nil when nothing is hanging.
    /// Applies the same expiry the reconsolidation path applies, so a stale slot
    /// reads as absent rather than as an expectation she is still holding.
    public func openCompletion(at now: Date) -> OpenCompletionRead? {
        guard let pending = pendingCompletion else { return nil }
        let age = now.timeIntervalSince(pending.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else { return nil }
        return OpenCompletionRead(
            openedAt: pending.recordedAt,
            expiresAt: pending.recordedAt.addingTimeInterval(Self.pendingCompletionMaxAge)
        )
    }
}

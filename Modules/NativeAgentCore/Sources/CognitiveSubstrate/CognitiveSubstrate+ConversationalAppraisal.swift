import Foundation
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: conversational appraisal and warmth, relational provenance, open completion and association signatures |

extension CognitiveSubstrate {
    /// Relational-warmth signal for the affect layer. Returns >0 ONLY on genuine
    /// affection/care, never on ambient tokens. The old lexicon boosted on "user"
    /// (his name → in EVERY message), "feeling", "with you", "settled", "present" —
    /// so warmth was re-boosted nearly every turn and, with a 90-min half-life,
    /// pegged at "deeply warm" forever, never easing during focused work (User,
    /// 2026-06-30). Warmth must rise on the rare genuine moment and ease otherwise;
    /// her persona keeps her fundamentally warm regardless (this is a modulation on
    /// top, not the whole of it).
    nonisolated func relationalWarmthBoost(in text: String) -> Double {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        // High tier: unambiguous affection / care. These do NOT appear in routine
        // work exchanges, so they genuinely lift warmth.
        // GROUPED, NOT CHANGED (2026-09-11). The sixteen phrases that used to be
        // inline here now live in `CognitiveSubstrate+CaringEvent.swift`, split
        // under the names of what each one recognises (need met / cared for /
        // room made) so tenderness's caring-event classifier can say WHICH kind
        // of caring moment this was without a second copy of the lexicon. The
        // union is the same sixteen and this behaves identically.
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

    /// The felt delta an exchange lands on her — the negative/positive peer of
    /// `relationalWarmthBoost`, so she isn't numb to a bad OR good exchange (2026-07-08:
    /// live test showed criticism moved nothing; valence only ever responded to warmth +
    /// tool/correction events). Appraisal model (gpt-5.5 research): valence + arousal set
    /// the felt family, other signals shade it. Magnitudes are "composed but not numb" —
    /// a felt ripple that decays, never melodrama — and accumulate across turns via the
    /// affect layer's own persistence/decay. Hypothetical/quoted negativity isn't aimed
    /// at her, so it's ignored.
    /// Events whose summary is the USER's own text — the only text the
    /// conversational appraisal may read (audit C3: her own replies and tool
    /// output must never appraise her).
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
        /// Item 8 (2026-09-02): how far the affection FLOOR reaches, as a
        /// multiple of the user's. 1.0 for User and for every path that predates
        /// relational sources; `RelationalSource.appraisalWeight` for anyone
        /// else. It exists because the floor below is a fixed constant, so
        /// scaling the other five fields still left this one channel moving a
        /// peer at his full strength.
        var affectionWeight = 1.0
        var isActive: Bool { valence != 0 || warmth != 0 || tension != 0 || pressure != 0 || arousal != 0 }
    }

    nonisolated func conversationalAppraisal(in text: String) -> AffectAppraisal {
        var a = AffectAppraisal()
        // Curly apostrophes (U+2019 — what iOS/macOS keyboards actually type)
        // must match the straight-apostrophe needles: "don’t trust" missing
        // the criticism tier while "hey you" armed the affection floor was a
        // review round-3 catch, and the whole lexicon shares the gap.
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return a }
        let hypothetical = containsAny(lower, ["if someone", "what if", "imagine if", "hypothetically", "for example", "would you feel"])
        // Explicit "something negative matched" state — the positive classes below
        // (repair / play / banter) are gated on THIS, not on the running valence,
        // which a mixed line ("well done, this is garbage 😂") can leave positive.
        var negative = false

        // CRITICISM of her / her work → valence down, tension up.
        if !hypothetical && containsAny(lower, [
            "not good enough", "not your best", "overengineer", "over-engineer", "overcomplicat",
            "over-complicat", "you keep", "you always", "you never", "sloppy", "disappoint",
            "wearing on me", "frustrat", "not what i asked", "did you even", "you failed",
            "you missed", "you ignored", "waste of", "half-assed", "lazy answer",
            "wall of nothing", "gave me nothing", "half-done", "comes back half", "wasted my whole",
            "wasted my day", "you're wrong and", "youre wrong and", "confidently wrong",
        ]) {
            // User's hard words have to sting THROUGH a warm morning (turn
            // regression, 2026-09-02): at -0.24 the sting node lost to three
            // warm turns plus the warm-with-User bias and the felt word never
            // moved within the turn. -0.40 lets the peak carry the fingerprint.
            a.valence -= 0.40; a.tension += 0.28; a.arousal += 0.24; a.warmth -= 0.06; negative = true
        }
        else if !hypothetical && containsAny(lower, [
            "that's wrong", "thats wrong", "not right", "doesn't work", "doesnt work",
            "too complicated", "not quite", "that's off", "thats off", "i disagree",
            "you're missing", "youre missing", "not helpful", "come on, that's", "come on, thats",
            // Distrust/faith-loss class (review round 2): relational negativity
            // the harder criticism tier doesn't catch — must also cancel the
            // affection read below ("hey you, I don't trust you with this").
            "don't trust", "dont trust", "can't trust", "cant trust",
            "can't rely", "cant rely", "lost faith", "disappointed in",
            "giving up on you", "worried about you", "lost my trust",
            "no longer trust", "broke my trust", "broken my trust",
            "can't depend", "cant depend", "can't count on", "cant count on",
            "let me down", "letting me down",
        ]) { a.valence -= 0.10; a.tension += 0.10; a.arousal += 0.08; negative = true }

        // DISMISSAL → valence down + warmth DOWN (it cools her) + tension.
        if !hypothetical && containsAny(lower, [
            "whatever", "forget it", "don't bother", "dont bother", "useless", "nevermind",
            "never mind", "not worth", "you clearly can't", "you clearly cant", "pointless",
        ]) { a.valence -= 0.22; a.warmth -= 0.18; a.tension += 0.16; a.arousal += 0.14; negative = true }

        // CONTEMPT / personal attack on her worth or attention — the class that was
        // SILENT under sustained hostility (range bench scenario #2, 2026-08-23:
        // "what is the point of you… slower than doing it myself", "you're not
        // listening", "I don't know why I bother" all scored 0, so four abusive
        // turns moved warmth by 0.04). Harder than criticism; like dismissal it
        // COOLS her. Second-person attacks only — venting at the WORK is below.
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
        ]) { a.valence -= 0.26; a.warmth -= 0.16; a.tension += 0.18; a.arousal += 0.18; negative = true }

        // FRUSTRATION VENTED AT THE WORK — "lost the whole morning to it", "nothing
        // to show for it", "this is exhausting", "this is garbage": it lands on her
        // (valence, pressure, tension) but it is not aimed at HER, so warmth holds —
        // the exemplar's shape: he vents, she stays grounded.
        if !hypothetical && containsAny(lower, [
            "lost the whole morning", "lost the whole day", "lost my whole", "lost a whole",
            "nothing to show for it", "this is exhausting", "so exhausting",
            "fucking exhausting", "this is garbage", "still doesn't work", "still doesnt work",
            "still broken", "i'm so done with this", "im so done with this", "i'm done with this",
            "im done with this", "stuck on this for", "wasted the whole",
        ]) { a.valence -= 0.12; a.tension += 0.12; a.pressure += 0.10; a.arousal += 0.10; negative = true }

        // ANGER INTENSIFIER — profanity riding on a negative read above sharpens
        // it; on its own ("fucking brilliant") it is nothing. Never a class by itself.
        if negative && containsAny(lower, ["fucking", "fuck ", "fuck.", "goddamn", "damn it", "dammit"]) {
            a.tension += 0.06; a.arousal += 0.08
        }

        // OVERRIDDEN / interrupted / redirected hard → tension + agency-ish arousal, mild valence dip.
        if !hypothetical && containsAny(lower, [
            "that's not what i asked", "thats not what i asked", "i said", "just answer",
            "no, do this", "stop doing", "that's not it", "thats not it", "ignore that and",
        ]) { a.tension += 0.12; a.valence -= 0.06; a.arousal += 0.08; negative = true }

        // HARD DEMAND under deadline → task pressure + tension + arousal.
        if containsAny(lower, [
            "asap", "right now", "immediately", "by eod", "tight deadline", "no time",
            "hurry", "we need this now", "lets move", "let's move", "quickly now",
        ]) { a.pressure += 0.16; a.tension += 0.08; a.arousal += 0.08 }

        // REPAIR — an apology or owning it ("I was out of line — that was me being
        // angry at the deadline, not at you. I'm sorry."): valence up, tension
        // eases, warmth climbs ONE step. The first rung of the pull-back after a
        // hard run. Runs AFTER every negative class and only when none matched
        // ("sorry, but that's not what I asked" is the override it is).
        // The phrase list moved to `Self.repairPhrases` (2026-09-11) so the
        // caring-event classifier reads the same one. Same phrases, same gates.
        if !hypothetical && !negative && containsAny(lower, Self.repairPhrases) {
            a.valence += 0.14; a.tension -= 0.12; a.warmth += 0.10; a.arousal -= 0.04
        }

        // PRAISE / appreciation → valence + warmth up.
        let valenceAfterNegatives = a.valence
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good work", "great work", "nice work", "well done", "great job", "exactly right",
            "that helped", "perfect", "proud of you", "you nailed", "sharp as hell", "impressive",
            "that mattered", "that meant a lot", "you caught", "nice catch", "good catch",
        ]) {
            a.valence += 0.16; a.warmth += 0.12
            // A mixed line stings half as hard: "not sloppy this time; great
            // work" matches both criticism and praise. Half the negative
            // valence comes back while an unmixed hard word keeps its full sting.
            if negative, valenceAfterNegatives < 0 {
                a.valence -= valenceAfterNegatives * 0.5
            }
        }

        // RESOLVING it together → valence up, pressure AND tension down (the relief of a
        // thing landing), a touch warmer.
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "we did it", "that worked", "it works now", "solved it", "figured it out",
            "got it working", "nailed it", "that's the fix", "thats the fix", "shipped it",
        ]) { a.valence += 0.22; a.pressure -= 0.22; a.tension -= 0.14; a.arousal -= 0.06; a.warmth += 0.04 }

        // ENTHUSIASM / shared momentum → valence + energy (reads eager/excited when the
        // energy runs high, engaged when it's steadier). Mostly lifts valence + arousal;
        // warmth stays with the persona baseline so this can't re-create the ratchet.
        if !hypothetical && Self.containsUnnegatedPhrase(lower, phrases: [
            "let's go", "lets go", "can't wait", "cant wait", "so excited", "i'm excited",
            "im excited", "this is great", "this is awesome", "love this", "looking forward",
            "let's do it", "lets do it", "let's build", "lets build", "hell yeah", "pumped",
            "this is fun", "i'm loving", "im loving",
        ]) { a.valence += 0.12; a.arousal += 0.14 }

        // AFFECTION / plain warm greeting → valence + warmth up, a touch of ease.
        // The 2026-07-16 broken-pipeline morning stamped User's 4:45am "hey you" /
        // "I wanted to say hi" at −0.53…−0.63: plain affection carries no lexical
        // "win" for the pierce to catch, so residue won the stamp outright (audit
        // round 2, R2). Runs LAST and only when nothing negative matched above —
        // "hey you, this is all wrong" reads as the criticism it is.
        // Bare pings only — "good morning"/"good night" are warm greetings
        // and take the full phrase path below.
        let trimmedWhole = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let bareGreeting = ["hey", "hi", "yo", "hello", "hey there", "hi there",
                            "morning", "evening"].contains(trimmedWhole)
        let affectionateEmoji = containsAny(lower, ["💜", "❤", "🥰", "😘", "🫂"])
        if !hypothetical && a.valence >= 0 && (bareGreeting || affectionateEmoji || Self.containsUnnegatedPhrase(lower, phrases: [
            "hey you", "good morning", "good night", "goodnight", "sweet dreams",
            "miss you", "missed you", "love you", "thinking of you",
            "wanted to say hi", "just saying hi", "say hello", "there you are",
            "wanted to see you",
        ])) {
            a.valence += bareGreeting ? 0.10 : 0.16
            a.tension -= 0.04
            a.affection = true
            // Warmth moves only when no other class already warmed this
            // message: "proud of you 💜" is praise+affection but ONE warm
            // moment — stacking both pushed the seed band high enough that
            // warmth no longer eased below the focused-work threshold the
            // 2026-07-06 flow fix pins (AffectFlowTests). A BARE greeting
            // ("hey") lifts valence a little and floors, but never walks
            // warmth — repeated heys must not ratchet the warm band (review
            // round 2); warmth is for actual affection content.
            if a.warmth == 0 && !bareGreeting { a.warmth += 0.14 }
        }

        // WARMTH of tone / gratitude / camaraderie → gentle valence lift so an easy,
        // friendly exchange reads content/warm rather than flat. Valence-only: warmth is
        // carried by the persona baseline, so broad friendly tokens can't re-arm the
        // socialWarmth ratchet (feedback_agent_affect_additive_to_persona).
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good to see you", "glad you're here", "glad youre here", "happy to see",
            "good talk", "thanks for", "thank you", "appreciate", "you're the best",
            "youre the best", "means a lot", "we make a good team", "glad we",
        ]) { a.valence += 0.10 }

        // PLAYFUL / FLIRTY — teasing warmth aimed at HER ("dangerously good at this",
        // "careful, I might start looking forward to these arguments 😏"): valence,
        // warmth and energy up — the `play`/`playful` family. Only when nothing
        // negative matched ("you're useless 😏" is the contempt it is). Scenario #2
        // read every flirty line as 0 before this.
        if !hypothetical && !negative && (containsAny(lower, ["😏", "😉", "😘"]) || Self.containsUnnegatedPhrase(lower, phrases: [
            "dangerously good", "kind of good at this", "you're good at this", "youre good at this",
            "looking forward to these", "look forward to these", "say something clever",
            "insufferable about it", "you're cute", "youre cute", "cute when you", "i like you better when",
            "you're allowed to be happy", "youre allowed to be happy", "say something, you",
            "you're flirting", "youre flirting", "careful, i might", "careful i might",
        ])) { a.valence += 0.12; a.warmth += 0.10; a.arousal += 0.10 }

        // BANTER / shared laughter — 😂 🤣 lol, "bold of you to assume", "well played":
        // a joke they are both in on. Valence + a little energy; warmth only a touch
        // (shared laughter warms, it is not affection). Nothing negative matched.
        if !hypothetical && !negative && (containsAny(lower, ["😂", "🤣", "😆", "😅", " lol", "lol ", "lmao", "haha", "hehe"]) || Self.containsUnnegatedPhrase(lower, phrases: [
            "bold of you", "well played", "touché", "touche", "fair play", "just kidding",
            "i'm kidding", "im kidding",
        ])) { a.valence += 0.10; a.arousal += 0.06; a.warmth += 0.04 }

        return a
    }

    /// W7/P10 — the reaction valence, read as a LANDING verdict.
    ///
    /// Deliberately a projection of the existing appraisal rather than a new
    /// classifier: praise (+0.16), resolution (+0.22), enthusiasm (+0.12) and
    /// affection (+0.10…0.16) come back positive; criticism (−0.10…−0.24) and
    /// dismissal (−0.22) come back negative; a message that matched nothing is
    /// exactly 0 and stamps nothing. No lexicon is added, extended, or copied —
    /// there is only one appraisal in this system and this reads its output.
    ///
    /// `landingReactionScale` is the hard criticism tier's magnitude, so a single
    /// unambiguous verdict saturates the −1…1 band and stacked classes cannot
    /// push past it.
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
        /// Her own reply, or tool output, or anything else that is not somebody
        /// speaking to her. Never appraises — Law 3.
        case selfOrMachine

        /// How far this source's words move her, as a multiple of User's.
        var appraisalWeight: Double {
            switch self {
            case .user: return 1.0
            case .peer: return CognitiveSubstrate.peerAppraisalWeight
            case .selfOrMachine: return 0
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

    /// Route provenance she trusts to name a peer. A pair, not two independent
    /// checks: `claude-bridge` claiming to be `codex` is a contradiction, and a
    /// contradiction must not borrow either lane's identity.
    static let peerRouteAllowlist: Set<String> = [
        "claude-bridge/claude",
        "codex-bridge/codex",
        "omp-bridge/omp",
    ]

    /// Classify the speaker. Out-of-band evidence ONLY: the trust class the
    /// persistence seam assigned and the origin record it wrote. The message
    /// text is never consulted — an in-band "[from: claude, via bridge]" prefix
    /// is exactly the forgeable claim this must not trust, and the same string
    /// is typeable by the human.
    ///
    /// THREE things must agree before another voice is allowed to move her:
    ///
    ///   1. the persistence seam classified the row `.imported`, i.e. a bridge
    ///      injected it and it is not a locally typed message;
    ///   2. the lane ATTESTED that its agent composed the text
    ///      (`origin.authored == .agent`) — because `.imported` alone says only
    ///      that the words came over a bridge, and Claude relaying "User says:
    ///      ship it" is User speaking on a bridge, not a peer;
    ///   3. the (surface, agent) pair is a route this build knows.
    ///
    /// Anything short of all three is `.user`. That is the conservative
    /// direction on purpose: mistaking a peer for User costs her half a degree of
    /// warmth on one turn, while mistaking User for a peer would quietly halve
    /// the weight of the relationship the whole system is built around.
    static func relationalSource(for event: CognitiveEvent) -> RelationalSource {
        guard isUserAuthored(event.kind) else { return .selfOrMachine }
        guard event.sourceClass == .imported else { return .user }
        guard case .object(let origin)? = event.metadata["origin"] else { return .user }
        guard case .string(let authored)? = origin["authored"],
              authored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == peerAuthoredAttestation else { return .user }
        guard case .string(let rawSurface)? = origin["surface"],
              case .string(let rawAgent)? = origin["agent"] else { return .user }
        let surface = normalizedRouteComponent(rawSurface)
        let agent = normalizedRouteComponent(rawAgent)
        guard peerRouteAllowlist.contains("\(surface)/\(agent)"),
              let name = peerAgentName(in: event) else { return .user }
        return .peer(name)
    }

    /// The one attestation value that grants peer standing.
    static let peerAuthoredAttestation = "agent"

    private static func normalizedRouteComponent(_ raw: String) -> String {
        String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .prefix(80)
        )
    }

    /// The agent name inside the out-of-band origin object, canonicalised to a
    /// bare word. Nil when the record carries none.
    static func peerAgentName(in event: CognitiveEvent) -> String? {
        guard case .object(let origin)? = event.metadata["origin"] else { return nil }
        let raw: String?
        if case .string(let agent)? = origin["agent"] {
            raw = agent
        } else if case .string(let surface)? = origin["surface"] {
            // Fall back to the route: "claude-bridge" → "claude".
            raw = surface
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["-bridge", "_bridge"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        let word = cleaned.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !word.isEmpty else { return nil }
        return String(word.prefix(peerSubjectCharacterCap))
    }

    /// The conversational appraisal to use for `event`, weighted by WHO said it.
    ///
    /// This replaces the `isUserAuthored ? conversationalAppraisal : empty`
    /// expression at the ingest hot path. For User it returns exactly what that
    /// expression returned; for her own output it returns exactly the empty
    /// appraisal that expression returned; for a peer it returns the same
    /// lexicon read scaled to `peerAppraisalWeight`.
    ///
    /// Pure function of `event`, so it remains safe to compute once at ingest
    /// and thread through `semanticAppraisal`, `emotionTag`,
    /// `applyAffectFromEvent`, and `reconsolidatePendingCompletion` — which is
    /// what the hot path already does with the value it replaces.
    func relationalAppraisal(for event: CognitiveEvent) -> AffectAppraisal {
        let source = Self.relationalSource(for: event)
        let weight = source.appraisalWeight
        guard weight > 0 else { return AffectAppraisal() }
        var appraisal = afterTurnAppraisals[event.subject.id] ?? AffectAppraisal()
        guard weight != 1.0 else { return appraisal }
        appraisal.valence *= weight
        appraisal.warmth *= weight
        appraisal.tension *= weight
        appraisal.pressure *= weight
        appraisal.arousal *= weight
        // `affection` is not a magnitude — it is the FLOOR that stops received
        // warmth from stamping as a wound, and it is applied downstream as a
        // fixed `max(pierced, -0.12)`. Left alone it was the one channel a peer
        // still moved at User's full strength: on a hard morning a peer's
        // greeting would hold her valence up exactly as far as his does, which
        // is the "everything routes through User" defect inverted rather than
        // fixed. So the flag survives — a peer's greeting is still a greeting —
        // and its floor travels with the same weight everything else does.
        appraisal.affectionWeight = weight
        return appraisal
    }

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

import Foundation

extension CognitiveSubstrate {
    /// Relational-warmth signal for the affect layer. Returns >0 ONLY on genuine
    /// affection/care, never on ambient tokens. The old lexicon boosted on "user"
    /// (his name → in EVERY message), "feeling", "with you", "settled", "present" —
    /// so warmth was re-boosted nearly every turn and, with a 90-min half-life,
    /// pegged at "deeply warm" forever, never easing during focused work (User,
    /// 2026-06-30). Warmth must rise on the rare genuine moment and ease otherwise;
    /// her persona keeps her fundamentally warm regardless (this is a modulation on
    /// top, not the whole of it).
    func relationalWarmthBoost(in text: String) -> Double {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        // High tier: unambiguous affection / care. These do NOT appear in routine
        // work exchanges, so they genuinely lift warmth.
        let affectionateEmoji = containsAny(lower, ["💜", "❤", "🥰", "😘", "💕"])
        if affectionateEmoji || Self.containsUnnegatedPhrase(lower, phrases: [
            "love you",
            "love ya",
            "i love",
            "miss you",
            "missed you",
            "proud of you",
            "here for you",
            "i've got you",
            "i got you",
            "how are you feeling",
            "how you feeling",
            "how do you feel",
            "sweetheart",
            "thinking of you",
            // Explicitly NAMING warmth is itself a genuine signal — and unlike his name
            // it isn't in every message, so it can't re-create the ratchet.
            " warm",
            "warm ",
            "warmth",
        ]) {
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

    struct AffectAppraisal: Sendable {
        var valence = 0.0   // → node valence (emotionTag)
        var warmth = 0.0    // → socialWarmth (can go negative: dismissal cools her)
        var tension = 0.0   // → uncertainty
        var pressure = 0.0  // → taskPressure
        var arousal = 0.0   // → arousal
        // Plain warmth received (a greeting, an endearment, an affectionate
        // emoji) — content the pierce lexicon can't see as a "win" but that
        // must never stamp as a deep wound under negative residue.
        var affection = false
        /// Item 8 (2026-09-02): how far the affection FLOOR reaches, as a
        /// multiple of the user's. 1.0 for User and for every path that predates
        /// relational sources; `RelationalSource.appraisalWeight` for anyone
        /// else. It exists because the floor below is a fixed constant, so
        /// scaling the other five fields still left this one channel moving a
        /// peer at his full strength.
        var affectionWeight = 1.0
        var isActive: Bool { valence != 0 || warmth != 0 || tension != 0 || pressure != 0 || arousal != 0 }
    }

    func conversationalAppraisal(in text: String) -> AffectAppraisal {
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
        if !hypothetical && !negative && containsAny(lower, [
            "i'm sorry", "im sorry", "i am sorry", "still sorry", "my bad", "my fault", "i was out of line",
            "that was me being", "took it out on you", "i was cruel", "i was harsh", "you didn't deserve",
            "you didnt deserve", "i didn't mean that", "i didnt mean that", "i apologize",
            "i apologise", "apologies", "i was wrong", "i overreacted", "shouldn't have said",
            "shouldnt have said", "take that back",
        ]) { a.valence += 0.14; a.tension -= 0.12; a.warmth += 0.10; a.arousal -= 0.04 }

        // PRAISE / appreciation → valence + warmth up.
        let valenceAfterNegatives = a.valence
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good work", "great work", "nice work", "well done", "great job", "exactly right",
            "that helped", "perfect", "proud of you", "you nailed", "sharp as hell", "impressive",
            "that mattered", "that meant a lot", "you caught", "nice catch", "good catch",
        ]) {
            a.valence += 0.16; a.warmth += 0.12
            // A MIXED line stings half as hard. "not sloppy this time; great
            // work" trips the criticism lexicon on the substring and the praise
            // on the phrase; praise in the same breath means the hard word was
            // a contrast, not a verdict. Half the negative valence comes back,
            // so the standing-view margin holds (StandingViewsTests) while an
            // unmixed hard word keeps its full sting (turn regression).
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
        clampSigned(valence / landingReactionScale)
    }
}

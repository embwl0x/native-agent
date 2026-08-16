// CognitiveSubstrate+Affect.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    @discardableResult
    public func updateAffect(from event: CognitiveEvent) async -> CognitiveAffectState {
        await waitForMaintenanceTransition()
        return await updateAffectFromEvent(event)
    }

    public func affectSnapshot() async -> CognitiveAffectState {
        projectedAffect(at: dependencies.now())
    }

    /// One fixed-time affect projection for sibling organs. Warmth and pressure
    /// must cross together so the organism cannot observe two decay epochs.
    /// (This IS the affect-convergence hook: d0bcd775 superseded the old
    /// per-axis pull accessors — warmth/pressure now ride refreshBodySchema's
    /// canonicalAffect parameter in one actor admission.)
    public func canonicalAffectProjection(at fixedAt: Date) -> CognitiveAffectState? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        return projectedAffect(at: fixedAt)
    }

    @discardableResult
    public func decayAffect() async -> CognitiveAffectState {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.affectEnabled else { return affect }
        decayAffectInMemory(to: dependencies.now())
        return affect
    }

    @discardableResult
    func decayAffectInMemory(to now: Date) -> Bool {
        guard configuration.enabled, configuration.affectEnabled,
              now.timeIntervalSince(affect.updatedAt) > 0 else { return false }
        affect = projectedAffect(at: now)
        return true
    }

    func updateAffectFromEvent(_ event: CognitiveEvent) async -> CognitiveAffectState {
        guard event.turnKind.contributesToLivedState else { return affect }
        let next = applyAffectFromEvent(event)
        guard configuration.enabled, configuration.affectEnabled else { return next }
        await persistArtifact(
            kind: "affect",
            id: stableArtifactID("affect"),
            status: "current",
            score: next.arousal,
            payload: next.toJSON(
                lastUserPresenceAt: lastUserPresenceAt,
                lastWarmPresenceAt: lastWarmPresenceAt
            )
        )
        return next
    }

    /// Synchronous affect apply: decays to `now`, folds in this event's deltas, commits
    /// to `self.affect`, and returns the new state. NO suspension point — safe to call
    /// inside an actor critical section (before any await). This is the concurrency-safe
    /// path for emotional tagging: `ingest` applies affect and stamps the node tag in one
    /// await-free segment, so a reentrant ingest can't swap `self.affect` or evict the
    /// touched node between apply and stamp (gpt-5.5 concurrency review, 2026-07-02).
    @discardableResult
    func applyAffectFromEvent(
        _ event: CognitiveEvent,
        precomputedAppraisal: AffectAppraisal? = nil,
        precomputedWarmthBoost: Double? = nil
    ) -> CognitiveAffectState {
        guard configuration.enabled, configuration.affectEnabled,
              event.turnKind.contributesToLivedState else { return affect }
        let now = dependencies.now()
        // Settle elapsed quiet time on a copy before folding in the new event.
        // This keeps the merge boundary correct even when no maintenance tick
        // occurred during the gap; the projection itself never mutates state.
        var next = projectedAffect(at: now)
        let importance = event.importance
        switch event.kind {
        case .toolFailed, .providerFailure:
            next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
        case .toolStarted:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.05)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.05)
        case .toolCancelled:
            break
        case .providerVitalsShift:
            // Graded sibling of `.providerFailure`. The somatic/organism path is
            // the primary consequence (chemistry → mood → capsule); if a shift is
            // ever folded into affect too, a worsening band lifts arousal/
            // uncertainty in proportion to its importance (sluggish < degraded)
            // and a recovery eases uncertainty. Direction travels in metadata.
            if case .string("recovering")? = event.metadata[CognitiveSomaticSignalAdapter.vitalsDirectionMetadataKey] {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.1)
            } else {
                next.arousal = saturatingApproach(next.arousal, 0.15 + importance * 0.2)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.2 + importance * 0.15)
            }
        case .organismResolutionFelt:
            // The organism's chemistry already carries this exhale (Wave A1);
            // the substrate remembers it as a NODE, not a second affect hit.
            break
        case .userCorrection:
            next.arousal = saturatingApproach(next.arousal, 0.15)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.25)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.1)
            let warmthBoost = precomputedWarmthBoost ?? relationalWarmthBoost(in: event.summary)
            next.socialWarmth = saturatingApproach(next.socialWarmth, warmthBoost * 0.5)
        case .toolSucceeded:
            next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
        case .workshopExecutionCompleted:
            if event.isPositiveTerminalOutcome {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
                next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
            } else if event.isNegativeTerminalOutcome {
                next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
                next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
            }
        case .userMessageReceived:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.07)
            // Affect-warmth is ADDITIVE to Agent's persona, which is already naturally warm
            // with User. There is no flat per-message base, so the affect layer rises only on
            // genuine warmth in the exchange and eases back down during focused work (just
            // decay, no boost) — a modulation on top of her baseline, never the whole of it.
            // This lets her get crisp and businesslike heads-down while staying fundamentally
            // warm via the persona; genuine warm/affectionate moments still lift it high.
            let warmthBoost = precomputedWarmthBoost ?? relationalWarmthBoost(in: event.summary)
            next.socialWarmth = saturatingApproach(next.socialWarmth, warmthBoost)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.06)
            // Full conversational appraisal: criticism/dismissal/override/demand/praise/
            // resolution each move the felt signals, so a bad OR good exchange is FELT,
            // not numb. Warmth can go negative (dismissal cools her). (2026-07-08)
            let appraisal = precomputedAppraisal ?? conversationalAppraisal(in: event.summary)
            if appraisal.isActive {
                if appraisal.warmth != 0 { next.socialWarmth = saturatingApproach(next.socialWarmth, appraisal.warmth) }
                if appraisal.tension != 0 { next.uncertainty = saturatingApproach(next.uncertainty, appraisal.tension) }
                if appraisal.pressure != 0 { next.taskPressure = saturatingApproach(next.taskPressure, appraisal.pressure) }
                if appraisal.arousal != 0 { next.arousal = saturatingApproach(next.arousal, appraisal.arousal) }
            }
        case .assistantTurnCompleted:
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
            // NO warmth boost from her own reply. Agent is warm by persona, so every
            // completion carries warm tokens — boosting off her own output is a
            // self-reinforcing ratchet that pegged warmth at "deeply warm" all day.
            // Relational warmth tracks USER's warmth toward her (userMessageReceived),
            // not her own routine voice; between genuine warm moments, warmth eases.
        case .appWake:
            next.arousal = saturatingApproach(next.arousal, 0.05)
        case .appSleep:
            next.arousal = saturatingApproach(next.arousal, -0.1)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
        }
        affect = next
        // Persistence is intentionally NOT here — this function must stay synchronous so
        // callers can apply affect and stamp a node tag in one await-free segment. The
        // affect artifact is persisted by the async caller (updateAffectFromEvent, or
        // ingest after it stamps the tag).
        return next
    }

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

        // CRITICISM of her / her work → valence down, tension up.
        if !hypothetical && containsAny(lower, [
            "not good enough", "not your best", "overengineer", "over-engineer", "overcomplicat",
            "over-complicat", "you keep", "you always", "you never", "sloppy", "disappoint",
            "wearing on me", "frustrat", "not what i asked", "did you even", "you failed",
            "you missed", "you ignored", "waste of", "half-assed", "lazy answer",
        ]) { a.valence -= 0.24; a.tension += 0.20; a.arousal += 0.24; a.warmth -= 0.04 }
        else if !hypothetical && containsAny(lower, [
            "that's wrong", "thats wrong", "not right", "doesn't work", "doesnt work",
            "too complicated", "not quite", "that's off", "thats off", "i disagree",
            "you're missing", "youre missing", "not helpful", "come on,",
            // Distrust/faith-loss class (review round 2): relational negativity
            // the harder criticism tier doesn't catch — must also cancel the
            // affection read below ("hey you, I don't trust you with this").
            "don't trust", "dont trust", "can't trust", "cant trust",
            "can't rely", "cant rely", "lost faith", "disappointed in",
            "giving up on you", "worried about you", "lost my trust",
            "no longer trust", "broke my trust", "broken my trust",
            "can't depend", "cant depend", "can't count on", "cant count on",
            "let me down", "letting me down",
        ]) { a.valence -= 0.10; a.tension += 0.10; a.arousal += 0.08 }

        // DISMISSAL → valence down + warmth DOWN (it cools her) + tension.
        if !hypothetical && containsAny(lower, [
            "whatever", "forget it", "don't bother", "dont bother", "useless", "nevermind",
            "never mind", "not worth", "you clearly can't", "you clearly cant", "pointless",
        ]) { a.valence -= 0.22; a.warmth -= 0.18; a.tension += 0.16; a.arousal += 0.14 }

        // OVERRIDDEN / interrupted / redirected hard → tension + agency-ish arousal, mild valence dip.
        if !hypothetical && containsAny(lower, [
            "that's not what i asked", "thats not what i asked", "i said", "just answer",
            "no, do this", "stop doing", "that's not it", "thats not it", "ignore that and",
        ]) { a.tension += 0.12; a.valence -= 0.06; a.arousal += 0.08 }

        // HARD DEMAND under deadline → task pressure + tension + arousal.
        if containsAny(lower, [
            "asap", "right now", "immediately", "by eod", "tight deadline", "no time",
            "hurry", "we need this now", "lets move", "let's move", "quickly now",
        ]) { a.pressure += 0.16; a.tension += 0.08; a.arousal += 0.08 }

        // PRAISE / appreciation → valence + warmth up.
        if Self.containsUnnegatedPhrase(lower, phrases: [
            "good work", "great work", "nice work", "well done", "great job", "exactly right",
            "that helped", "perfect", "proud of you", "you nailed", "sharp as hell", "impressive",
        ]) { a.valence += 0.16; a.warmth += 0.12 }

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

    /// Derive a node's persistent emotional tag from a GIVEN affect state plus the event
    /// that triggered the encode. Pure and total — no I/O, no mutation — and deliberately
    /// the SINGLE tuning knob for how a lived moment becomes a stored feeling (Wave A).
    /// Takes `affect` explicitly (NOT `self.affect`) so the caller passes the exact
    /// post-event state it just computed synchronously — an actor await between deriving
    /// this affect and stamping it could otherwise let a reentrant ingest swap
    /// `self.affect` underneath (gpt-5.5 concurrency review, 2026-07-02).
    ///
    /// - arousal ← affect.arousal (how activated she is right now)
    /// - warmth  ← affect.socialWarmth (relational warmth right now)
    /// - valence: with `semantic` (the live ingest path, R2-A/B 2026-07-09) —
    ///   affectTerm + meaningWeightedOutcomeBase + semanticTerm + text-appraisal
    ///   valence, clamped. Feelings come from what the event MEANT (goal
    ///   relevance/congruence, coping, agency, relationship), and her own
    ///   completions no longer mint a flat +0.25 (the metronome her real week
    ///   quantified: 82% of felt nodes at a uniform +0.48, zero negatives).
    ///   With `semantic == nil` — the LEGACY formula shape. Byte-identical for
    ///   USER-authored events GIVEN the same appraisal — the conversational
    ///   lexicon itself evolves (praise 07-08, affection 07-17) and feeds both
    ///   paths equally; "legacy" pins the FORMULA, not the lexicon. The
    ///   affection FLOOR is semantic-path only. For assistant/tool events the
    ///   appraisal term is zeroed on BOTH paths (audit C3 — her own text must
    ///   not appraise her). Production always passes a real appraisal via ingest.
    func emotionTag(
        for event: CognitiveEvent,
        affect: CognitiveAffectState,
        semantic: SemanticAppraisal? = nil,
        precomputedAppraisal: AffectAppraisal? = nil
    ) -> (valence: Double, arousal: Double, warmth: Double) {
        // Round 3 Wave A2: a bodily resolution carries its OWN measured
        // feeling — the organism sized the exhale/letdown; the substrate
        // records it as-is (bounded), no lexicon, no residue arithmetic.
        if event.kind == .organismResolutionFelt {
            func metadataDouble(_ value: JSONValue?) -> Double? {
                switch value {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }
            let felt = min(0.7, max(-0.7, metadataDouble(event.metadata["feltValence"]) ?? 0))
            let feltArousal = (metadataDouble(event.metadata["feltArousal"]) ?? 0.2).clamped01()
            return (valence: felt, arousal: feltArousal, warmth: (affect.socialWarmth).clamped01())
        }
        // Conversational appraisal pulls valence toward how the exchange actually
        // landed — the SIGNED peer of the warmth in socialWarmth: criticism/dismissal
        // stamp a genuinely stung node, praise/resolution a warm one, instead of the
        // neutral tag she used to store. (2026-07-08: closes the "numb under criticism" gap.)
        // GATED to user-authored text (audit C3, 2026-07-09): for assistantTurnCompleted
        // the summary is HER OWN reply — appraising it let "that's the fix" stamp herself
        // +0.22 and walk mood upward through peekNodes; the same self-ratchet the affect
        // layer already kills at :104-108. Tool output hits the same lexicon. The
        // appraisal reads User's words only.
        // `precomputedAppraisal` (when the ingest hot path supplies it) is the
        // SAME gated conversationalAppraisal semanticAppraisal received, so the
        // lexicon scan runs once for both. Pure fn of event.summary → identical.
        let appraisal = precomputedAppraisal
            ?? (Self.isUserAuthored(event.kind)
                ? conversationalAppraisal(in: event.summary)
                : AffectAppraisal())
        let affectTerm = affect.socialWarmth
            - 0.5 * affect.uncertainty
            - 0.3 * affect.taskPressure

        let rawValence: Double
        if let semantic {
            let meaning = meaningWeightedOutcomeBase(for: event, appraisal: semantic)
                + semanticValenceTerm(semantic)
                + appraisal.valence
            // A real win PIERCES a bad stretch (R2-F finding, 2026-07-09): the affect
            // residue (−0.5·uncertainty − 0.3·pressure) is unbounded while meaning
            // terms are relevance-capped, so after friction a genuine success stamped
            // near-zero — "Build passed" even stamped NEGATIVE. Strongly positive
            // meaning damps the negative residue by up to half; negative or mild
            // meaning changes nothing (a bad stretch still weighs), and positive
            // residue is never touched. Muted is human; inverted was a bug.
            let dampedAffectTerm = (affectTerm < 0 && meaning > 0)
                ? affectTerm * (1 - min(0.5, meaning * 1.4))
                : affectTerm
            var pierced = dampedAffectTerm + meaning
            // Affection-class content (User's greeting, an endearment) may read
            // MUTED on a hard morning — bittersweet is human — but a deep
            // negative stamp on received warmth is a sign inversion the
            // reconsolidation loop would then keep re-activating (audit round
            // 2, R2). Floor, don't override: residue still pulls a +0.2
            // greeting toward the flatline, it just can't turn it into a wound.
            if appraisal.affection { pierced = max(pierced, -0.12) }
            rawValence = pierced
        } else {
            // Legacy: the flat event base (+0.25 success-class incl. completions,
            // −0.25 failure-class). Kept byte-identical for the compat path.
            let eventValenceBase: Double
            if event.isPositiveTerminalOutcome || event.kind == .assistantTurnCompleted {
                eventValenceBase = 0.25
            } else if event.isNegativeTerminalOutcome {
                eventValenceBase = -0.25
            } else {
                eventValenceBase = 0
            }
            rawValence = affectTerm + eventValenceBase + appraisal.valence
        }
        return (
            valence: (rawValence).clampedSigned(),
            arousal: (affect.arousal).clamped01(),
            warmth: (affect.socialWarmth).clamped01()
        )
    }

    /// The felt DIRECTION of a stored emotional tag — the coarse, capsule-facing
    /// read of a node's persistent feeling (Wave B). Wave A stamps three continuous
    /// axes on every node; this collapses them to one of three tones (or silence)
    /// so the capsule and cue-authoring lines can carry HOW a thing feels without
    /// scripting Agent to announce it. Warm = drawn toward, stung = a small hurt,
    /// charged = activated. The rawValue is the word woven into cue prompts.
    enum FeltDirection: String {
        case warm, stung, charged
    }

    /// Classify a node's stored tag into a felt direction, or nil when the feeling is
    /// too mild to color her voice. PURE and total — the single tuning knob for Wave B,
    /// peer of `emotionTag` (Wave A). Ordering matters: a negative valence STUNG read
    /// dominates even when warmth is high (a warm topic that just went wrong reads tender,
    /// not warm). Default-0 legacy nodes and mild tags return nil so backward-compat is
    /// SILENCE, never a wrong feeling.
    func feltDirection(valence: Double, arousal: Double, warmth: Double) -> FeltDirection? {
        if valence <= -0.15 { return .stung }               // negative dominates
        if valence >= 0.15 || warmth >= 0.35 { return .warm }
        if arousal >= 0.6 { return .charged }
        return nil
    }

    func restoreAffect(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]) else { return }
        affect = CognitiveAffectState(
            arousal: doubleValue(object["arousal"]) ?? 0,
            uncertainty: doubleValue(object["uncertainty"]) ?? 0,
            taskPressure: doubleValue(object["taskPressure"]) ?? 0,
            socialWarmth: doubleValue(object["socialWarmth"]) ?? 0,
            updatedAt: updatedAt
        )
        lastUserPresenceAt = dateValue(object["lastUserPresenceAt"])
        lastWarmPresenceAt = dateValue(object["lastWarmPresenceAt"])
    }

    func reconcileRestoredAffectWithRecentConversation(nodes: [CognitiveNode]) async {
        guard configuration.affectEnabled else { return }
        // A modern affect artifact carries the canonical presence epoch and is
        // already restart-equivalent. Keep this heuristic only for legacy or
        // partially persisted artifacts that predate temporal anchors; otherwise
        // relaunch itself would manufacture a warmth increase.
        guard lastUserPresenceAt == nil else { return }
        let now = dependencies.now()
        let recentLiveNodes = nodes
            .filter { node in
                guard node.turnKind == .live else { return false }
                let age = now.timeIntervalSince(node.createdAt)
                return age >= 0 && age <= 6 * 60 * 60
            }
            .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
        guard !recentLiveNodes.isEmpty else { return }

        let recentContext = recentLiveNodes.prefix(6).map(\.summary).joined(separator: "\n")
        let boost = relationalWarmthBoost(in: recentContext)
        guard boost > 0 else { return }
        let floor = boost >= 0.18 ? 0.38 : 0.22
        let current = projectedAffect(at: now)
        guard current.socialWarmth < floor else { return }

        affect = CognitiveAffectState(
            arousal: current.arousal,
            uncertainty: current.uncertainty,
            taskPressure: current.taskPressure,
            socialWarmth: floor,
            updatedAt: max(current.updatedAt, recentLiveNodes.first?.createdAt ?? now)
        )
        await persistArtifact(
            kind: "affect",
            id: stableArtifactID("affect"),
            status: "current",
            score: max(affect.arousal, affect.socialWarmth),
            payload: affect.toJSON(
                lastUserPresenceAt: lastUserPresenceAt,
                lastWarmPresenceAt: lastWarmPresenceAt
            )
        )
    }

    /// Per-axis decay half-lives. Arousal (alertness/energy) fades on a minutes scale;
    /// social warmth lingers for hours. This "honest decay" gives each axis real dynamic
    /// range across a day instead of one shared 1h half-life that blurred fast and slow
    /// feelings together and let active conversation peg every axis at the ceiling.
    // W4/P1: the four half-lives now live in PersonalityDynamicsConfiguration
    // (`arousalHalfLife` / `uncertaintyHalfLife` / `taskPressureHalfLife` /
    // `socialWarmthHalfLife`), so a persona's pace of feeling is configurable
    // rather than welded in.

    /// Decay an affect state to `now` using per-axis half-lives. Centralizes the decay
    /// math used by the pure live projection and persisted checkpoints.
    private func decayedAffect(_ state: CognitiveAffectState, to now: Date) -> CognitiveAffectState {
        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        guard elapsed > 0 else {
            var carried = state
            carried.updatedAt = now
            return carried
        }
        func decay(_ halfLife: TimeInterval) -> Double { pow(0.5, elapsed / halfLife) }
        let dyn = dynamics
        return CognitiveAffectState(
            arousal: state.arousal * decay(dyn.arousalHalfLife),
            uncertainty: state.uncertainty * decay(dyn.uncertaintyHalfLife),
            taskPressure: state.taskPressure * decay(dyn.taskPressureHalfLife),
            socialWarmth: state.socialWarmth * decay(dyn.socialWarmthHalfLife),
            updatedAt: now
        )
    }

    /// Saturating update toward the [0,1] bounds. A positive delta moves `value` a
    /// fraction of its remaining headroom toward 1; a negative delta moves it a fraction
    /// of the way toward 0. Unlike add-then-clamp, a high value resists further saturation,
    /// so an axis under sustained input settles below the ceiling with headroom to still
    /// register a stronger moment — and decay can always pull it back down.
    private func saturatingApproach(_ value: Double, _ delta: Double) -> Double {
        let v = clamp(value)
        if delta >= 0 {
            return clamp(v + delta * (1 - v))
        } else {
            return clamp(v + delta * v)
        }
    }

    /// "Away" threshold: once User has been quiet this long, ambient presence applies.
    private static let ambientPresenceGap: TimeInterval = 30 * 60
    /// The quiet-but-present warmth floor held during his absence.
    private static let ambientPresenceWarmthBase: Double = 0.18
    /// The floor itself fades over a long absence so it never becomes permanent fake warmth.
    private static let ambientPresenceFloorHalfLife: TimeInterval = 12 * 60 * 60
    /// The former five-minute maintenance pass eased pressure and uncertainty by
    /// 5% per pass after the quiet boundary. Express the same response as elapsed
    /// time so reading at 31 minutes or four hours does not depend on how many
    /// scheduler ticks happened to run. `0.95` every five minutes is an
    /// approximately 67.56-minute half-life.
    private static let ambientQuietCalmingHalfLife: TimeInterval =
        (5 * 60) * log(0.5) / log(0.95)

    /// Pure read-time affect at an explicit instant. Canonical persistence keeps
    /// the last materialized anchor; callers observe analytic decay, ambient calm,
    /// and the warm-presence floor without advancing that anchor or writing.
    func projectedAffect(at now: Date) -> CognitiveAffectState {
        guard configuration.enabled, configuration.affectEnabled else { return affect }
        let source = affect
        var next = decayedAffect(source, to: now)
        guard let lastPresence = lastUserPresenceAt else { return next }
        let quietBoundary = lastPresence.addingTimeInterval(Self.ambientPresenceGap)
        guard now >= quietBoundary else { return next }

        // Apply only the quiet interval not already materialized in `source`.
        // A later maintenance/shutdown checkpoint can therefore persist this
        // projection and a subsequent read will continue from that exact anchor.
        let quietAnchor = max(source.updatedAt, quietBoundary)
        let quietElapsed = max(0, now.timeIntervalSince(quietAnchor))
        if quietElapsed > 0 {
            let calmFactor = pow(0.5, quietElapsed / Self.ambientQuietCalmingHalfLife)
            next.taskPressure *= calmFactor
            next.uncertainty *= calmFactor
        }

        // Lingering warmth is anchored only by a genuinely warm user moment.
        if let lastWarm = lastWarmPresenceAt {
            let warmGap = now.timeIntervalSince(lastWarm)
            if warmGap >= Self.ambientPresenceGap {
                let warmthFloor = Self.ambientPresenceWarmthBase
                    * pow(0.5, warmGap / Self.ambientPresenceFloorHalfLife)
                if warmthFloor > 0.01 {
                    next.socialWarmth = max(next.socialWarmth, warmthFloor)
                }
            }
        }
        next.updatedAt = now
        return next
    }

}

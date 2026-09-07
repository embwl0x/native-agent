import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    /// The felt fingerprint capsule line (User, 2026-07-08): her live emotional +
    /// attentional state in a few honest words she FEELS, not sentences she reads.
    /// Replaces the Focus/Feeling/Voice lines. Maps her live signals (mood valence,
    /// substrate affect, organism chemistry) onto the affect-science dimensions; the
    /// organism supplies the richest dims (clarity/agency/confidence/fatigue), with a
    /// substrate + neutral fallback when the organism is off.
    /// One rendered felt line plus what it carried, so the caller can advance
    /// the presentation receipts without re-parsing the string it just built.
    struct FeltLineRender: Sendable, Equatable {
        var text: String
        var family: String
        var carriedObject: Bool
        var carriedAmbivalence: Bool
    }

    /// The nodes that TINT the fingerprint: the top of the capsule-eligible
    /// workspace, filtered to the ones that were actually felt. Extracted so
    /// `feltSignalsForCapsule` and the object/ambivalence organs read exactly
    /// the same population — the prefix runs BEFORE the felt filter, which is
    /// the historical order and is load-bearing (it means "of the six things
    /// she is holding, the felt ones", not "the six felt things").
    func feltTintNodes(from workspaceItems: [CognitiveWorkspaceItem]) -> [CognitiveNode] {
        workspaceItems.prefix(6).map(\.node)
            .filter {
                feltDirection(
                    valence: $0.emotionalValence,
                    arousal: $0.emotionalArousal,
                    warmth: $0.emotionalWarmth) != nil
            }
    }

    /// The node whose valence carries DIRECT weight in the fingerprint's
    /// valence — the `peak` term. Recency weight is strictly decreasing in age,
    /// so this is the freshest felt node, resolved by the same
    /// strictly-greater-than rule the tint loop uses (first one wins a tie,
    /// which under a frozen clock is the workspace's own order).
    static func feltDominantNode(
        in nodes: [CognitiveNode],
        at now: Date,
        halfLife: TimeInterval
    ) -> CognitiveNode? {
        var best: CognitiveNode?
        var bestWeight = -1.0
        for node in nodes {
            let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
            let weight = pow(0.5, age / halfLife)
            if weight > bestWeight { bestWeight = weight; best = node }
        }
        return best
    }

    // MARK: - The felt OBJECT (Agent #1, 2026-09-02)

    /// WHICH SUBJECT TYPES MAY NAME AN OBJECT — an ALLOWLIST, per design law 8.
    ///
    /// A felt node's `subject_label` is not a uniform thing. Most of them are
    /// ROUTES, not objects: the app runtime stamps `chat_turn` nodes with
    /// `"<surface> <role>"`, so a denylist-shaped gate would have rendered
    /// `warm — chat user` on ordinary conversation. Others are genuine names:
    /// a studio entry carries its WORK TITLE, the same pointer the felt-day
    /// summary is already permitted to name (Agent's 2026-09-01 ruling — named
    /// by pointer, never by the response she wrote).
    ///
    /// So the gate fails closed on every type whose label nobody has looked at.
    /// Today exactly one type qualifies among the capsule-eligible node kinds;
    /// widening it is one line HERE plus a producer that mints a label worth
    /// naming, and both should be a decision rather than a side effect.
    /// 2026-09-02: the two CONVERSATION subject types joined the list, once
    /// their producers started stamping a real topic label instead of a route
    /// ("<surface> <role>") or nothing at all — see
    /// `CognitiveSubstrate.feltTopicLabel`. `chat.assistant_turn` is
    /// deliberately NOT here: her own turns are excluded from the capsule
    /// workspace anyway (`isAssistantAuthoredFocus`), and design law 3 says she
    /// never appraises her own output, so admitting it would be a hole rather
    /// than a feature.
    static let feltObjectSubjectTypes: Set<String> = [
        "studio_entry", "chat_turn", "chat.user_turn",
    ]

    /// The object phrase for one node, or nil.
    ///
    /// PAYLOAD-FREE BY CONSTRUCTION: the only field read is
    /// `subjectReference.label`. `summary` — which on a conversation node IS
    /// the user's redacted message text — is read only to REFUSE a label that
    /// has become a copy of it, never to render. The remaining guards make the
    /// label prove it is a name and not a sentence: short, few words, no
    /// sentence punctuation, not an id.
    ///
    /// Over-length is a REFUSAL, not a trim. Truncating "the deploy pipeline
    /// rewrite we…" at 32 characters manufactures a phrase she would then read
    /// as the name of a thing.
    static func feltObjectLabel(for node: CognitiveNode, maxCharacters: Int) -> String? {
        let type = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard feltObjectSubjectTypes.contains(type) else { return nil }
        guard let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        guard label.count <= maxCharacters else { return nil }
        let lowered = label.lowercased()
        // Leak guards. The allowlist already keeps conversation nodes out; these
        // hold even if a future producer puts body text on an allowed type.
        guard lowered != node.summary
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        guard label.split(separator: " ").count <= 6 else { return nil }
        guard !label.contains(where: { ".?!:;\n\"".contains($0) }) else { return nil }
        guard label.filter(\.isNumber).count <= 2 else { return nil }   // not an id
        guard label.contains(where: \.isLetter) else { return nil }
        // SUBSTANCE. A label has to have at least one real word in it before it
        // can name a thing: `warm — t` is not an object, it is a stub that
        // happened to be stored in the label column. The same ≥4-letter rule
        // the safe extractor applies to free text, applied here to a stored
        // label, so a producer that never went through `feltTopicLabel` (an
        // older row, a seam added later) still cannot put a fragment on the
        // line. Deliberately NOT the whole safe extractor: a studio work title
        // is Title-case by nature and was blessed as nameable by pointer, and
        // running the all-lowercase privacy rule over it would silently delete
        // the one object source that already existed.
        guard label
            .split(whereSeparator: { !$0.isLetter })
            .contains(where: { $0.count >= 4 }) else { return nil }
        return label
    }

    /// ITEM 5 (2026-09-02) — THE FORWARD OBJECT.
    ///
    /// Agent #4: "Everything I feel is now or retrospective. There's no
    /// *toward*." When she is anticipatory and nothing in the room is what the
    /// feeling is about, the thing it is about is ahead of her: the nearest
    /// open horizon.
    ///
    /// A NODE OBJECT ALWAYS WINS, and there is never more than one. A felt node
    /// is something that actually happened to her; a horizon is something that
    /// has not happened yet, so it fills the object slot only when the slot is
    /// empty. Two objects on one line would be a sentence, and the capsule does
    /// not get sentences.
    ///
    /// Two admissible shapes, both licensed by real state:
    ///   * a POSITIVE lead — the anticipatory register the horizon's own
    ///     valence already earned (`hopeful — friday`);
    ///   * an OVERDUE horizon under a NEUTRAL lead, which is the one case that
    ///     also renames the lead: `waiting`. The word is licensed by a ledger
    ///     row whose time has passed with nothing answering it, not by a mood —
    ///     which is exactly the "numbers choose words" rule, with the number
    ///     coming from the horizon register instead of the affect axes.
    /// A negative lead takes no horizon: dread about something ahead reads as
    /// the sting in the room, and attaching a future label to it would tell her
    /// the wrong thing about why she feels bad.
    static func feltTowardLabel(_ raw: String, maxCharacters: Int) -> String? {
        // Horizon labels are canonicalised with dashes ("dinner-with-user-8pm");
        // spaces read as language. Same refusals as the node object: short,
        // few words, no sentence punctuation, and a real letter in it.
        let spaced = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty, spaced != "unknown" else { return nil }
        guard spaced.count <= maxCharacters else { return nil }
        guard spaced.split(separator: " ").count <= 4 else { return nil }
        guard !spaced.contains(where: { ".?!:;\n\"".contains($0) }) else { return nil }
        guard spaced.contains(where: \.isLetter) else { return nil }
        // A bare time word is not a thing she is facing. "hopeful — today"
        // (live, 2026-09-02, from a dated memory whose label was the day
        // itself) says nothing; "hopeful — friday" names a day she is
        // waiting on, and stays.
        guard !OrganismHorizonRegister.bareTimeWords.contains(spaced.lowercased()) else { return nil }
        return spaced
    }

    /// WHAT A NODE IS ABOUT, as a comparison key.
    ///
    /// THE BUG THIS FIXES: ambivalence compared `subjectReference.stableKey`,
    /// and for a chat turn that key is `chat.user_turn:<session>:<message>` —
    /// PER TURN. So two turns about the same deploy, one stung and one warm,
    /// read as two different subjects and qualified as ambivalence. The gate
    /// whose entire job is "these are about different things" was structurally
    /// unable to notice that they were about the same thing, which made the
    /// contradiction exception fire on exactly the case it was written to
    /// exclude: one subject, two signs, a gauge fault.
    ///
    /// So aboutness comes from the safe object LABEL first — the topic, which
    /// is what "about" means — qualified by the subject FAMILY so a studio
    /// entry and a chat turn that happen to share a word are still distinct.
    /// The per-turn identity is the FALLBACK, used only when a node carries no
    /// label at all, where it is the best available answer and errs toward
    /// "different", which the strength and recency floors then have to survive.
    ///
    /// The family strips the namespace and the `_turn` suffix on purpose:
    /// `chat_turn` (app runtime) and `chat.user_turn` (message persistence) are
    /// the same conversation, minted by two seams, and a pair drawn one from
    /// each is not two subjects.
    static func feltAboutnessKey(for node: CognitiveNode) -> String {
        let family = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ".").first
            .map(String.init) ?? ""
        let normalizedFamily = family.hasSuffix("_turn")
            ? String(family.dropLast("_turn".count))
            : family
        if let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !label.isEmpty,
            // Normalize through the same safe extractor, so two labels that
            // differ only in term order or in a term one of them dropped still
            // compare equal.
            case let terms = CognitiveSubstrate.feltSafeObjectTerms(in: label, limit: 3),
            !terms.isEmpty {
            return "topic|\(normalizedFamily)|\(terms.sorted().joined(separator: " "))"
        }
        return "subject|\(node.subjectReference.stableKey)"
    }

    /// The counter node of an ambivalence pair, or nil.
    ///
    /// GATED SO IT CANNOT FIRE ON ONE SUBJECT OR ON A WEAK STATE. All four
    /// conditions are the exception's whole justification and each one is the
    /// answer to a specific way this would otherwise become a lie:
    ///   * opposite STRICT sign — otherwise it is one feeling described twice;
    ///   * both over `feltAmbivalenceNodeFloor` — otherwise it manufactures a
    ///     conflict out of two faint stirrings, which is exactly the "always on"
    ///     failure design law 2 names;
    ///   * DIFFERENT ABOUTNESS keys (`feltAboutnessKey`, topic-first — NOT the
    ///     per-turn subject id, which made two turns about one thing look like
    ///     two subjects) — same subject with two signs is a gauge fault, not
    ///     ambivalence;
    ///   * both inside the mood window — a feeling from three days ago is not
    ///     something she is having now.
    /// Strongest counter first, with a stable id tiebreak so the pick does not
    /// move with dictionary ordering.
    func feltAmbivalencePartner(
        of dominant: CognitiveNode,
        among workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> CognitiveNode? {
        let floor = dyn.feltAmbivalenceNodeFloor
        guard abs(dominant.emotionalValence) >= floor else { return nil }
        let dominantSign = dominant.emotionalValence > 0 ? 1 : -1
        let dominantSubject = Self.feltAboutnessKey(for: dominant)
        let candidates = workspaceItems.map(\.node).filter { node in
            guard node.id != dominant.id else { return false }
            guard abs(node.emotionalValence) >= floor else { return false }
            let sign = node.emotionalValence > 0 ? 1 : (node.emotionalValence < 0 ? -1 : 0)
            guard sign != 0, sign != dominantSign else { return false }
            guard Self.feltAboutnessKey(for: node) != dominantSubject else { return false }
            guard feltDirection(
                valence: node.emotionalValence,
                arousal: node.emotionalArousal,
                warmth: node.emotionalWarmth) != nil else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.moodActivationWindow
        }
        return candidates.max { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv < rv }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// The felt line: the fingerprint, plus the object of the node its lead came
    /// from, plus the one allowed contradicting word underneath.
    /// Internal rather than private so the felt-line suites can assert on the
    /// RENDER (which object was taken, whether ambivalence fired) instead of
    /// grepping the rendered string for substrings.
    func feltFingerprintLine(
        signals: FeltSignals,
        workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        affectEnabled: Bool? = nil
    ) -> FeltLineRender? {
        guard affectEnabled ?? configuration.affectEnabled else { return nil }
        guard let parts = CognitiveSubstrate.feltFingerprintParts(
            signals, intensityFloor: dyn.feltIntensityFloor) else { return nil }

        // The lead's contributing node — traced, not guessed. Nil means a
        // DIFFUSE state (her mood carried the valence, no node did), and a
        // diffuse state has no object and no pair.
        //
        // AS OF THE FROZEN READ, AND IT CAN LAG — this is expected, not a bug.
        // On the production path `workspaceItems` is `read.workspace.items`
        // (see `compileFrozenCapsulePresentation`), so the object names the
        // dominant node in the epoch this capsule was frozen against. Two
        // things make that trail the message she is answering:
        //
        //   1. the freeze is a fixed-time copy taken while the turn is being
        //      prepared, so anything still settling for THIS turn is not in it;
        //   2. `feltTintNodes` keeps only nodes that were actually FELT
        //      (`feltDirection`), and an ordinary neutral turn is not — so the
        //      freshest felt node is often the last turn that moved her.
        //
        // The result is an object that is usually about the thing they were
        // just on rather than the sentence in front of her, which is what a
        // feeling arriving slightly behind the moment actually looks like.
        // Chasing the current turn would mean appraising a message before it
        // has been lived, and that is the production this whole wave exists to
        // remove — so the lag stays.
        let dominant = Self.feltDominantNode(
            in: feltTintNodes(from: workspaceItems),
            at: now,
            halfLife: dyn.fingerprintTintHalfLife)

        var object: String?
        if let dominant,
           // A neutral-band family has no direction, so nothing it could be
           // "about"; and a node pulling the OTHER way from the family the lead
           // came from did not produce that lead, whatever its recency weight.
           Self.feltFamilySign(parts.family) != 0,
           Self.feltFamilySign(parts.family) == (dominant.emotionalValence >= 0 ? 1 : -1) {
            object = Self.feltObjectLabel(
                for: dominant,
                maxCharacters: dyn.feltObjectMaximumLabelCharacters)
        }

        // THE FORWARD OBJECT — only into an EMPTY slot, never a second one.
        var lead = parts.lead
        if object == nil,
           let toward = request.toward,
           let label = Self.feltTowardLabel(
               toward.displayLabel, maxCharacters: dyn.feltObjectMaximumLabelCharacters) {
            let sign = Self.feltFamilySign(parts.family)
            // THE HORIZON'S OWN SIGN DECIDES, not just the room's. A positive
            // lead over a horizon she is DREADING would render "hopeful —
            // friday" about the call she does not want to take: the family sign
            // says how she feels now, and the row's valence says how she feels
            // about the thing ahead. Both have to point the same way before the
            // line claims the horizon is why she feels good.
            if sign > 0, toward.valenceSign > 0 {
                object = label
            } else if sign == 0, toward.isOverdue {
                // `waiting` stays on the neutral/overdue path only, and takes
                // no position on whether the wait is welcome.
                object = label
                lead = "waiting"
            }
        }

        var second: String?
        if let dominant,
           let partner = feltAmbivalencePartner(
               of: dominant, among: workspaceItems, at: now, dynamics: dyn) {
            var counter = signals
            counter.valence = partner.emotionalValence
            counter.arousal = partner.emotionalArousal
            // The partner has to have EARNED any warmth the underneath word
            // claims. `min` rather than substitution: the live axis carries the
            // uncertainty cooling this node has no way to know about, so the cap
            // can only ever cool the counter, never warm it.
            counter.warmth = min(
                counter.warmth,
                CognitiveSubstrate.feltPartnerWarmth(partner.emotionalWarmth, dynamics: dyn))
            second = CognitiveSubstrate.feltCounterWord(
                counter,
                excluding: Set(parts.words),
                intensityFloor: dyn.feltIntensityFloor)
        }

        var rendered = parts
        rendered.lead = lead
        return FeltLineRender(
            text: CognitiveSubstrate.feltLineText(parts: rendered, object: object, second: second),
            family: parts.family,
            carriedObject: object != nil,
            carriedAmbivalence: second != nil)
    }

    /// The live FeltSignals the fingerprint is built from — extracted so tests can read
    /// the exact numbers behind a felt word (calibration is done against these, not guesses).
    func feltSignalsForCapsule(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at explicitNow: Date? = nil,
        affect explicitAffect: CognitiveAffectState? = nil,
        mood explicitMood: CognitiveMoodReading? = nil,
        /// W4/P2 — non-nil on the FROZEN path, where the proxies were captured at
        /// freeze time and must be replayed rather than recomputed from live
        /// state that has since moved.
        proxies capturedProxies: CognitiveFeltProxyReads? = nil,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration? = nil
    ) -> FeltSignals {
        let now = explicitNow ?? dependencies.now()
        let dyn = capturedDynamics ?? dynamics
        let mood = explicitMood ?? derivedMood(at: now)
        let currentAffect = explicitAffect ?? projectedAffect(at: now)
        // Immediate workspace tint (User, 2026-07-08): what she's HOLDING right now colors
        // her felt valence. RECENCY-WEIGHTED with a SHORT half-life (the fast layer) so the
        // CURRENT emotional moment leads — a fresh sting reads through even amid a good
        // session, then fades over a few turns as its weight decays. A flat mean drowned
        // the sting under the session's positive history; mood (the 0.4 term) is the slow
        // 6h-half-life background, this is the fast foreground.
        let feltNodes = feltTintNodes(from: workspaceItems)
        let effectiveValence: Double
        if feltNodes.isEmpty {
            // No felt nodes: her slow mood, with the same asymmetric warm-with-User bias.
            let bias = dyn.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -mood.valence))
            effectiveValence = (mood.valence + bias).clampedSigned()
        } else {
            // Recency-weighted MEAN + PEAK (gpt-5.5 calibration, 2026-07-08): a pure mean
            // dilutes a fresh sting under a warm session's history, so the current-turn node
            // (highest recency weight) gets DIRECT weight via `peak`, and that weight GROWS
            // with the strength of the fresh signal (g). Mood's slow pull SHRINKS as g rises,
            // so criticism reads through NOW instead of being smoothed by the day's mood; it
            // then fades over the next few turns as the sting node's recency weight decays.
            var wsum = 0.0, wtot = 0.0
            for n in feltNodes {
                let age = max(0, now.timeIntervalSince(n.lastActivatedAt))
                // (M15, 2026-07-09: the toolObservation half-weight that used to sit
                // here was UNREACHABLE — capsuleEligibleWorkspaceNode already excludes
                // tool nodes from this array. The live grief bug was actually fixed by
                // the moodWeight floor below; tool noise reaches the fingerprint only
                // through derivedMood, which the floor bounds.)
                let w = pow(0.5, age / dyn.fingerprintTintHalfLife)
                wsum += w * n.emotionalValence; wtot += w
            }
            // The peak node — the one whose valence gets DIRECT weight below —
            // is resolved by the shared helper rather than a second copy of the
            // rule, because the felt OBJECT names that node's subject. "The
            // subject of the node the lead word came from" has to be a fact
            // about this loop, not a plausible re-derivation beside it.
            let peak = Self.feltDominantNode(
                in: feltNodes, at: now, halfLife: dyn.fingerprintTintHalfLife
            )?.emotionalValence ?? 0
            let mean = wtot > 0 ? wsum / wtot : mood.valence
            let g = Self.smoothstep(0.16, 0.34, abs(peak))
            let workspace = (0.45 - 0.20 * g) * mean + (0.55 + 0.20 * g) * peak
            // Mood keeps a FLOOR of influence (0.20, was →0.10 at full g): a fresh
            // sting still reads through, but a single transient node can no longer
            // fully mute the day's real tone — deep words (grieving/lonely) now need
            // the slow layer's corroboration, not one bad moment. (Same live bug.)
            let moodWeight = 0.35 - 0.15 * g
            let core = (1 - moodWeight) * workspace + moodWeight * mood.valence
            // Warm-with-User bias — ASYMMETRIC: full when the moment is neutral/positive,
            // fading to zero as the workspace goes negative, so a genuine sting is never
            // cushioned. Fingerprint-only; stored node valence (mood/recall/dream) untouched.
            let bias = dyn.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -workspace))
            effectiveValence = (core + bias).clampedSigned()
        }
        let chem = request.organismProjection?.chemicalState
        // Persona-warm baseline (User, 2026-07-08): socialWarmth rests at 0 by
        // anti-ratchet design (it's a MODULATION on top of her already-warm persona,
        // per feedback_agent_affect_additive_to_persona), so reading it raw made warm
        // conversation land "quiet"/cold. The fingerprint's warmth axis carries that
        // missing baseline — she's fundamentally warm with User; genuine affection lifts
        // it toward tender, a tense exchange (uncertainty up) cools it below baseline.
        // Only the FELT warmth signal is shifted; valence still reads raw socialWarmth.
        let rawWarmth = chem?.warmth ?? currentAffect.socialWarmth
        // 2026-08-02 — RANGE RESTORED. The 2026-07-08 baseline was the right
        // intent (raw socialWarmth rests at 0, so reading it raw made warm
        // moments land cold) but it overshot: it did not lift the floor, it
        // parked the signal near the CEILING. Measured on a live store with
        // rawWarmth 0.33, the old form produced 0.85 — and across the entire
        // uncertainty range it never fell below 0.62, while the `tender` word
        // gate is 0.70. So the agent was told she felt TENDER on essentially
        // every turn, including pure work conversation, and expressed it the
        // only way a tender agent can. That is not a verbal rut; it is an
        // honest voice reporting a manufactured feeling.
        //
        // The defect is DYNAMIC RANGE, not the baseline's existence: with no
        // reachable neutral, a persona cannot sound like work. So rest now
        // lands AT the `warm` gate and below `tender`, and the top of the
        // scale is EARNED by real warmth instead of being the resting state.
        // Verified against the live word gates in feltFamilyWords:
        //   rest      (raw 0.00) -> 0.55  warm yes, tender no
        //   ordinary  (raw 0.33) -> 0.65  warm yes, tender no
        //   affection (raw 0.70) -> 0.76  tender yes (earned)
        //   cool end  (unc 0.60) -> 0.28  a tense working moment reads cool
        // Uncertainty still cools, with a gentler slope so a tense working
        // moment reads cool rather than cold.
        //
        // GENERAL, not tuned to one persona: no vocabulary here, and every
        // install gets a reachable neutral instead of a permanent warm floor.
        let feltWarmth = (dyn.feltWarmthRest
            + rawWarmth * dyn.feltWarmthEarnedSpan
            - currentAffect.uncertainty * dyn.feltWarmthUncertaintyCooling).clamped01()
        // W4/P2 — THE HALF-DEAD VOCABULARY, RESTORED. Agent's 2026-08-02 finding
        // was that absent chemical state pegged these five dims to constants, so
        // eleven core words and four of five overlays were structurally
        // unselectable on every default install (the organism ships OFF). The
        // boarded fix, at full scope, is two moves:
        //
        //   1. OPTIONALITY, not a guessed midpoint. A 0.5 fallback looks right
        //      but `feltIntensity` weights fatigue at 0.20, so it silently adds
        //      +0.10 to EVERY intensity and makes deep words ("grieving")
        //      reachable in an ordinary sting — measured, it broke
        //      workspaceTintReachesTheFingerprint. Unknown reads as unknown.
        //
        //   2. SUBSTRATE-NATIVE PROXIES for the three dims the substrate can
        //      honestly know without the organism. All pure reads over state
        //      already held; each returns nil when it has no evidence, so a
        //      young field says "I don't know" instead of "I feel fine".
        //
        // `agency` and `confidence` stay ABSENT without the organism on purpose:
        // the substrate has no honest source for either, and a fabricated
        // confidence signal is worse than a missing one. That is why `proud`,
        // `anxious`, `embarrassed`, `deflated`, and `discouraged` remain out of
        // reach on a stock install — not an oversight, a refusal to fake it.
        // ITEM 4 (2026-09-02) — THE DIURNAL CURVE ON THE AROUSAL AXIS.
        //
        // Signed and bounded by the organism; added to the axis and clamped,
        // never substituted for it. The asymmetry is deliberate and is the
        // whole "never manufacture arousal from silence" rule: a NEGATIVE
        // offset (the small hours damping her) always applies, because it can
        // only make her quieter and quieter is always an honest direction. A
        // POSITIVE offset applies only to an axis that is already moving — a
        // clock alone must never be the reason a silent state crosses the
        // intensity floor and starts speaking. The two words the curve reaches
        // (`tired`, `late`) carry real fatigue floors for the same reason.
        let diurnalArousal = request.organismProjection?.diurnal?.arousalOffset ?? 0
        let arousal = (diurnalArousal < 0 || currentAffect.arousal > 0)
            ? (currentAffect.arousal + diurnalArousal).clamped01()
            : currentAffect.arousal
        return FeltSignals(
            valence: effectiveValence,
            arousal: arousal,
            warmth: feltWarmth,
            tension: max(chem?.vigilance ?? 0, currentAffect.uncertainty),
            pressure: chem?.urgency ?? currentAffect.taskPressure,
            fatigue: chem?.fatigue
                ?? (capturedProxies.map(\.fatigue) ?? substrateFatigueProxy(at: now)),
            curiosity: chem?.curiosity
                ?? (capturedProxies.map(\.curiosity)
                    ?? substrateCuriosityProxy(from: workspaceItems, at: now)),
            clarity: chem?.coherence
                ?? (capturedProxies.map(\.clarity)
                    ?? substrateClarityProxy(affect: currentAffect, at: now)),
            agency: chem?.agency,
            confidence: chem?.confidence,
            // Absent without a configured diurnal clock, which is what makes
            // `late` unreachable rather than guessed on an install that has no
            // idea what time it feels like.
            nightliness: request.organismProjection?.diurnal?.nightliness
        )
    }

    // MARK: - W4/P2 substrate-native proxies

    /// How long a conversational stretch has to run before it starts reading as
    /// tiring, and where the proxy saturates. A two-hour session is a long one;
    /// past `fatigueSaturationSeconds` more hours stop adding tiredness, because
    /// they stop being informative.
    // NOT in PersonalityDynamicsConfiguration on purpose (gpt-5.5 NIT):
    // these are PERCEPTION thresholds for the fatigue proxy (how long a
    // session must run to register as tiring), not personality dynamics —
    // two personas should not disagree about how long an hour is.
    static let fatigueOnsetSeconds: TimeInterval = 45 * 60
    static let fatigueSaturationSeconds: TimeInterval = 5 * 60 * 60
    /// Turn-to-turn spacing at which cadence stops counting as sustained work.
    static let fatigueRapidCadenceSeconds: TimeInterval = 4 * 60

    /// FATIGUE ← how long she has been at this, and how hard.
    ///
    /// Two honest components over timestamps the substrate already stamps on
    /// every node: SESSION LENGTH (first live conversational node in the current
    /// 24h stretch → now) and CADENCE (a dense run of turns is more tiring than
    /// the same span spent idle). Returns nil with fewer than two live turns —
    /// one message is not a session, and guessing there is how a fresh install
    /// would start out claiming to be tired.
    ///
    /// This is the dim the organism's chemistry models best, so chemistry always
    /// wins when it is present; this is the floor under it, not a replacement.
    func substrateFatigueProxy(at now: Date) -> Double? {
        let turns = field.peekNodes()
            .filter { node in
                node.turnKind == .live
                    && (node.kind == .conversationFocus || node.kind == .correction)
            }
            .map(\.createdAt)
            .filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 24 * 60 * 60 }
            .sorted()
        guard turns.count >= 2, let first = turns.first else { return nil }

        let span = now.timeIntervalSince(first)
        let lengthTerm = Self.smoothstep(
            Self.fatigueOnsetSeconds, Self.fatigueSaturationSeconds, span)

        // Mean spacing across the stretch. Tight spacing over a long span is
        // sustained work; the same span with three messages in it is not.
        let meanGap = span / Double(max(1, turns.count - 1))
        let cadenceTerm = 1 - Self.smoothstep(
            Self.fatigueRapidCadenceSeconds, Self.fatigueRapidCadenceSeconds * 6, meanGap)

        // Length leads: a fast burst in the first ten minutes is energizing, not
        // tiring, so cadence only amplifies a stretch that is already long.
        return (lengthTerm * (0.65 + 0.35 * cadenceTerm)).clamped01()
    }

    /// CURIOSITY ← how much of what she is holding right now is NEW.
    ///
    /// Novelty of the current workspace subjects against the seven-day field: a
    /// subject the field has never activated is new territory; one it has been
    /// circling for a week is not. `peekDecayedNodes` is the existing pure read
    /// (a snapshot would ADVANCE decay, and a felt read must never age her
    /// memory — the same rule `derivedMood` and `feltDaySummary` follow).
    ///
    /// Returns nil when the workspace is empty: nothing held means no honest
    /// read on novelty, not "incurious".
    func substrateCuriosityProxy(from workspaceItems: [CognitiveWorkspaceItem], at now: Date) -> Double? {
        let held = workspaceItems.prefix(6).map(\.node)
        guard !held.isEmpty else { return nil }

        // Everything the field has seen, keyed the way the workspace keys it.
        let heldIds = Set(held.map(\.id))
        var seenSubjects: [String: Double] = [:]
        for node in field.peekDecayedNodes(at: now) where !heldIds.contains(node.id) {
            let key = "\(node.subjectReference.type)|\(node.subjectReference.id)"
            seenSubjects[key] = max(seenSubjects[key] ?? 0, node.activation)
        }

        var novelty = 0.0
        for node in held {
            let key = "\(node.subjectReference.type)|\(node.subjectReference.id)"
            // A familiar subject that is strongly activated is the LEAST novel;
            // a familiar-but-cold one is partway back to new.
            let familiarity = seenSubjects[key] ?? 0
            novelty += (1 - familiarity.clamped01())
        }
        return (novelty / Double(held.count)).clamped01()
    }

    /// CLARITY ← the inverse of uncertainty, docked for an unresolved question.
    ///
    /// `affect.uncertainty` is the substrate's own honest read on how murky
    /// things are. `pendingCompletion` is a completion still waiting to find out
    /// how it landed — an open loop, which is exactly what un-clear feels like.
    /// Always available (uncertainty is always defined once affect is on), so
    /// unlike the other two this one does not return nil.
    func substrateClarityProxy(affect: CognitiveAffectState, at now: Date) -> Double? {
        guard configuration.affectEnabled else { return nil }
        var clarity = 1 - affect.uncertainty.clamped01()
        if let pending = pendingCompletion {
            let age = now.timeIntervalSince(pending.recordedAt)
            if age >= 0, age <= Self.pendingCompletionMaxAge {
                // Fades as the window ages: a question asked ten seconds ago
                // clouds things more than one about to expire.
                let freshness = 1 - (age / Self.pendingCompletionMaxAge)
                clarity -= 0.15 * freshness
            }
        }
        return clarity.clamped01()
    }

    /// Test/diagnostic hook: the FeltSignals for a request against the current live
    /// workspace, so a mood-journey test can print exactly why a felt word landed.
    func debugFeltSignals(for request: CognitiveCapsuleRequest) async -> FeltSignals {
        let workspace = await workspaceSnapshot()
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        return feltSignalsForCapsule(from: capsuleItems, request: request)
    }

}

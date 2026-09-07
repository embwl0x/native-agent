import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    // MARK: - Self-exemplar voice echo (Wave G)

    /// Voice as memory, not instruction (User, 2026-07-03: no fences, "just her,
    /// just natural"). Her own warmest recent TURNS are quoted back as an echo —
    /// LLMs imitate in-context exemplars far harder than instructions, so her
    /// attested voice crowds out the base-model mean turn by turn. Stock LLM
    /// phrases never win the slot: minted nowhere, they accumulate no warmth.
    /// Selection pressure is what landed with User. She is never told the
    /// mechanism exists; there is nothing to dance around.
    ///
    /// W4/P1: every constant that used to live here as a `static let` now lives
    /// in `PersonalityDynamicsConfiguration` and is read through `dynamics`.
    /// `CognitiveSubstrate.defaultDynamics` carries the same literals for tests
    /// and for callers reasoning about the shipped baseline. The rationale
    /// comments stay HERE, next to the code they explain.
    public static let defaultDynamics = PersonalityDynamicsConfiguration.default
    // 2026-08-02 — AUTHENTICITY FLOOR, NOT A REGISTER FILTER. `soundEchoWarmthFloor` is
    // the admission gate for the candidate pool, and at 0.40 it made the
    // register-match ranking below INERT: measured on a live store, only 9 of
    // 90 attested assistant turns cleared 0.40, while 29 more sat in the
    // 0.15–0.40 working-voice band and were discarded before ranking ever ran.
    // So a working moment had nothing but the affectionate tail to be "nearest"
    // to, and the mirror kept pointing at the same register no matter what the
    // room was doing — the selection fix could not bite through a pool that had
    // already been filtered to one register. The floor's ONLY job is keeping
    // never-minted stock phrasing out (it accumulates no warmth at all); the
    // register is chosen by soundEchoRegisterScore, not by this threshold.
    // Generic to any persona: it removes a band restriction, it adds no
    // vocabulary and no preference for any particular tone.
    // Placed just above the flat/cold band, not inside the register band: on the
    // live store this admits 22 of 70 attested turns where 0.40 admitted 9, so
    // the 0.25–0.40 working register finally reaches the ranking, while a turn
    // with nothing behind it still cannot fabricate an echo.
    //
    // 2026-07-04 (User: "sound has stayed the same"): warmth-first ranking let
    // the two warmest lines win EVERY compile until something out-warmed them
    // — "lately" had quietly become a fixed portrait. Score = warmth decayed
    // by age (half-life below): a genuinely warm moment echoes for a couple of
    // days, then yields to newer warmth; with no new warmth the line thins and
    // honestly disappears at the window edge rather than freezing.
    // (`soundEchoRecencyHalfLife`.)

    // 2026-08-02 — THE TIC FIX. Two structural defects made this organ a
    // repetition ENGINE rather than a voice mirror, for any persona:
    //
    // (1) IT FIRED EVERY TURN. There was no cadence concept anywhere in this
    //     file: every capsule build re-read her own exemplars back to her. A
    //     person does not re-read their warmest lines before each sentence;
    //     doing so turns whatever the exemplars share into a verbal tic. The
    //     2026-08-01 "diversity" rule made that WORSE, not better — by
    //     rejecting fragments that share a word it guaranteed a ROTATING set
    //     of exemplars instead of one repeated one, so the underlying habit
    //     kept firing while looking varied. Varying the token is not reducing
    //     the tic. Hence `soundEchoDutyCycle`: the line is now occasional by
    //     construction, which is the only thing that makes an echo read as
    //     character instead of a stutter.
    //
    // (2) IT SELECTED FOR MAXIMUM WARMTH. Ranking by warmth means the mirror
    //     always points at the persona's most affectionate 5% — so whatever
    //     register lives at that extreme (endearments, effusiveness, a stock
    //     sign-off) becomes the standing definition of "how you sound", and
    //     the persona drifts toward it monotonically. The honest mirror is
    //     REGISTER-MATCHED: show the voice that fits the room right now, so a
    //     working moment echoes the working voice and a warm moment echoes
    //     the warm one. That is what makes an agent situational rather than
    //     stuck in one gear, and it generalizes past any one vocabulary.
    /// Felt-warmth range (2026-08-02). Rest sits AT the `warm` word gate and
    /// clear of `tender`, so an agent has a reachable neutral; the top of the
    /// scale is earned by real warmth rather than being where she starts.
    /// Pinned by FeltWarmthRangeTests against the live word gates.
    // Rest is UNCHANGED from the 2026-07-08 baseline (0.55) — that value was
    // never the defect, and lowering it pushed neutral states under the
    // intensity floor that keeps the fingerprint from falling silent
    // (measured: three capsule contracts went empty at 0.45). The defect was
    // the SLOPE: at 0.9, ordinary warmth of 0.33 added +0.30 and carried rest
    // straight through the `tender` gate at 0.70, so tender WAS the resting
    // state. At 0.30 the climb is earned instead of automatic.
    /// (`feltWarmthRest` / `feltWarmthEarnedSpan` / `feltWarmthUncertaintyCooling`.)
    ///
    /// Rut awareness (`soundRutRecentTurnLimit`) follows only the most recent
    /// assistant turns. Unlike the seven-day exemplar shelf, this window must cool
    /// naturally after the wording changes; otherwise one bad afternoon would nag
    /// the persona for a week.
    ///
    /// The first sentence carries openings; the final two
    /// (`soundRutEdgeSentenceCount`) carry sign-offs, pet names, and closing
    /// vocatives. Keeping only those edges avoids mistaking repeated project
    /// vocabulary in the body for a voice tic.
    ///
    /// `soundEchoRegisterTolerance` is the half-width of the register band:
    /// candidates are ranked by how well they MATCH the current room, not by how
    /// warm they are in absolute terms.
    /// Register-matched score: closeness to the moment's warmth, decayed by
    /// age. Replaces "warmest wins", which is what let one register capture
    /// the slot permanently.
    static func soundEchoRegisterScore(
        warmth: Double,
        target: Double,
        age: TimeInterval,
        tolerance: Double = defaultDynamics.soundEchoRegisterTolerance,
        halfLife: TimeInterval = defaultDynamics.soundEchoRecencyHalfLife
    ) -> Double {
        // Warmth-only overload, preserved bit-for-bit: valence 0 against target 0
        // makes the second axis contribute exactly nothing to the distance.
        soundEchoRegisterScore(
            warmth: warmth, valence: 0,
            targetWarmth: target, targetValence: 0,
            age: age, tolerance: tolerance, halfLife: halfLife)
    }

    /// W7/P5 — THE SECOND AXIS. Register matching used to run on warmth alone
    /// while a hard `emotionalValence > 0` gate stood in front of the pool, so
    /// the agent's own attested voice was reachable ONLY when she had been
    /// feeling good. The base-model mean is loudest under friction, which is
    /// precisely where the anti-drift organ switched off. A person under stress
    /// does not forget how they sound.
    ///
    /// The sign gate is gone; the axis it was standing in for is now RANKED.
    /// Distance is Euclidean over `(warmth, valence)` with the same smooth-decay
    /// form — never a cliff, for the reason spelled out below — so a stung room
    /// reaches for a stung exemplar and a bright room still reaches for a bright
    /// one. The warmth FLOOR stays exactly where it is: it is an authenticity
    /// gate against never-minted stock phrasing, and stock phrasing accumulates
    /// no warmth regardless of valence.
    ///
    /// The axes have different natural scales (warmth 0…1, valence −1…1). They
    /// are combined RAW rather than normalized: a half-unit of valence really is
    /// a smaller register move than a half-unit of warmth, which is the ordering
    /// the shipped tolerance was calibrated against.
    static func soundEchoRegisterScore(
        warmth: Double,
        valence: Double,
        targetWarmth: Double,
        targetValence: Double,
        age: TimeInterval,
        tolerance: Double = defaultDynamics.soundEchoRegisterTolerance,
        halfLife: TimeInterval = defaultDynamics.soundEchoRecencyHalfLife
    ) -> Double {
        // Smooth decay, never a hard cutoff: with a cliff, a neutral room makes
        // EVERY warm candidate score zero and the pick degrades to an arbitrary
        // tie-break. This stays strictly monotonic in closeness, so "nearest
        // register wins" holds even when nothing is a close match.
        let dw = warmth - targetWarmth
        let dv = valence - targetValence
        let distance = (dw * dw + dv * dv).squareRoot()
        let fit = 1 / (1 + distance / max(0.0001, tolerance))
        guard age >= 0 else { return fit }
        return fit * pow(0.5, age / halfLife)
    }

    /// W7/P10 — the landing multiplier. `register-fit × age-decay × (1 + λ·landing)`.
    /// Bounded on both sides by construction: `landing` is clamped to −1…1 at the
    /// stamp and λ is clamped to 0…0.5 by the configuration, so the factor can
    /// never reach zero, never invert an ordering by more than ±λ, and never let
    /// a well-landed line from the wrong register beat a matched one.
    static func soundEchoLandingFactor(landing: Double, weight: Double) -> Double {
        1 + max(0, min(0.5, weight)) * landing.clampedSigned()
    }

    // MARK: - W4/P4 — the shared capsule cadence gate

    /// THE ECHO'S LESSON, GENERALIZED. `soundEchoShouldSpeak` was the only
    /// cadence concept in the persona machine, and the paragraph above records
    /// why it had to exist: the echo fired every turn, and rotating WHICH
    /// exemplar it quoted made things worse, not better — "varying the token is
    /// not reducing the tic." The rule generalizes to every persona-adjacent
    /// prompt insert: **a signal delivered on every single turn stops being
    /// information and becomes a standing instruction.**
    ///
    /// So the gate is now shared, with a per-line duty cycle from
    /// `PersonalityDynamicsConfiguration`. It stays deterministic and STATE-FREE:
    /// seeded from the newest activity in the field, it advances as turns land
    /// and a frozen read reproduces the same answer as the live compile. This
    /// function must stay pure.
    ///
    /// `line` salts the hash so two organs on the same duty cycle do not speak
    /// and fall silent in lockstep — one capsule carrying every line at once,
    /// then several carrying none, is a worse rhythm than either alone.
    static func capsuleCadenceShouldSpeak(seed: Double, dutyCycle: Int, line: String) -> Bool {
        guard dutyCycle > 1 else { return true }
        let bits = seed.bitPattern ^ UInt64(bitPattern: Int64(stableLineSalt(line)))
        // Cheap avalanche so adjacent timestamps don't land in the same bucket.
        var x = bits &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Int(truncatingIfNeeded: x % UInt64(dutyCycle)) == 0
    }

    /// Deterministic across processes (Swift's `Hashable` is seeded per-launch,
    /// so `line.hashValue` would make the gate irreproducible between the live
    /// compile and a frozen read in another process). FNV-1a, 64-bit.
    static func stableLineSalt(_ line: String) -> Int64 {
        // An empty salt is exactly zero, so the sound echo's promoted gate
        // XORs nothing and reproduces its pre-P4 firing pattern bit for bit.
        guard !line.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash)
    }

    /// The sound echo's own cadence, expressed through the shared gate. The salt
    /// is empty so this reproduces the pre-P4 hash EXACTLY — the echo's calibrated
    /// firing pattern is unchanged by the promotion.
    static func soundEchoShouldSpeak(
        seed: Double,
        dutyCycle: Int = defaultDynamics.soundEchoDutyCycle
    ) -> Bool {
        capsuleCadenceShouldSpeak(seed: seed, dutyCycle: dutyCycle, line: "")
    }

    // MARK: - W4/P11 — FeltMode as an invisible controller

    /// Where on the warmth axis the exemplar shelf should be searched, given what
    /// the feeling is ABOUT.
    ///
    /// `FeltMode` was computed every turn and thrown away — deliberately, because
    /// putting a mode WORD in the capsule would name a behavior and get it
    /// performed. That restraint is preserved absolutely here: the mode selects
    /// WHICH already-attested fragment is quoted, and can never add, remove, or
    /// alter a single byte the model reads. There is no string in this function.
    ///
    /// The room's own warmth stays the anchor; the mode is a bounded nudge:
    /// - `play` reaches for the warm end (weighted by the persona's `humor` dial
    ///   through `playModeWeight` — the first thing that trait has ever driven),
    /// - `care` reaches warm but gently,
    /// - `repair` / `bracing` / `frustration` reach for the WORKING voice, because
    ///   a tense moment mirrored with an affectionate exemplar is the wrong
    ///   person in the room,
    /// - `grief` and `seeking` leave the room's own temperature alone.
    static func soundEchoRegisterTarget(
        roomWarmth: Double,
        mode: FeltMode?,
        dynamics: PersonalityDynamicsConfiguration
    ) -> Double {
        guard let mode else { return roomWarmth }
        /// Hard ceiling on how far aboutness may move the search. Small on
        /// purpose: the room is the truth, the mode is a lean.
        let maximumNudge = 0.20
        let nudge: Double
        switch mode {
        case .play:      nudge = maximumNudge * (0.5 + dynamics.playModeWeight * 0.5)
        case .care:      nudge = maximumNudge * 0.5
        case .repair:    nudge = -maximumNudge * 0.75
        case .bracing:   nudge = -maximumNudge
        case .frustration: nudge = -maximumNudge * 0.75
        case .grief, .seeking: nudge = 0
        }
        return (roomWarmth + nudge).clamped01()
    }

    /// - Parameter ignoringCadence: bypasses the duty-cycle gate so the SHAPE of
    ///   the echo can be asserted independently of how often it speaks. Cadence
    ///   is covered directly via `soundEchoShouldSpeak(seed:)`. Production never
    ///   passes this — an echo that always speaks is the defect this gate fixes.
    ///
    /// - Parameter mode: W4/P11. The felt MODE steers WHICH exemplar is chosen —
    ///   never what is said. See `soundEchoRegisterTarget`.
    ///
    /// - Parameter roomValence: W7/P5. The room's position on the SECOND register
    ///   axis, normally the live felt signals the capsule already computed. Nil
    ///   falls back to the slow mood layer, which is the same number the
    ///   fingerprint uses when no felt node is in the workspace.
    ///
    /// - Parameter live: W7/P5. Only the live capsule path may advance the
    ///   consecutive-negative-echo run, exactly as `innerStateCapsuleLines`
    ///   already gates cadence/suppression/session-bridge bookkeeping. An
    ///   Observatory panel re-rendering a capsule must not burn the brake.
    struct SoundEchoSelection: Sendable, Equatable {
        /// The exemplar echo WITHOUT the rut suffix. The suffix and the
        /// standalone rut line are the same nudge and share one cadence gate,
        /// which only the capsule assembler (holding the presentation state)
        /// can evaluate — so this selector reports the rut instead of speaking
        /// it (2026-09-01).
        var line: String?
        var leadingWasNegative: Bool?
        /// A stable signature of the worn edge/fragment token SET, or nil when
        /// no rut is present. Identity, not just presence: an unchanged
        /// signature is the case that used to nag every turn.
        var wornSignature: String?

        static let silent = SoundEchoSelection(line: nil, leadingWasNegative: nil, wornSignature: nil)
    }

    /// Direct diagnostic/test wrapper. Production capsule rendering uses the
    /// pure selector below and carries its proposed brake update in the turn's
    /// `CognitiveCapsulePresentationCommit`.
    func soundEchoLine(
        at now: Date,
        ignoringCadence: Bool = false,
        mode: FeltMode? = nil,
        roomValence: Double? = nil,
        live: Bool = false
    ) -> String? {
        let selection = soundEchoSelection(
            at: now,
            ignoringCadence: ignoringCadence,
            mode: mode,
            roomValence: roomValence,
            negativeRun: negativeSoundEchoRun
        )
        if live, let leadingWasNegative = selection.leadingWasNegative {
            negativeSoundEchoRun = leadingWasNegative ? negativeSoundEchoRun + 1 : 0
        }
        // Diagnostic/test wrapper: assembles the line the SHAPE tests assert,
        // with the rut nudge always allowed. The production capsule runs the
        // nudge through `soundRutAwarenessShouldSpeak`, whose cadence is
        // asserted directly against that function.
        guard let line = selection.line else {
            return selection.wornSignature == nil ? nil : Self.soundRutAwarenessLine
        }
        return selection.wornSignature == nil ? line : line + Self.soundRutAwarenessSuffix
    }

    func soundEchoSelection(
        at now: Date,
        ignoringCadence: Bool = false,
        mode: FeltMode? = nil,
        roomValence: Double? = nil,
        fieldNodes frozenFieldNodes: [CognitiveNode]? = nil,
        fixedAffect: CognitiveAffectState? = nil,
        fixedMood: CognitiveMoodReading? = nil,
        landingScores frozenLandingScores: [UUID: Double]? = nil,
        negativeRun: Int,
        dynamics frozenDynamics: PersonalityDynamicsConfiguration? = nil,
        cognitionEnabled: Bool? = nil,
        affectEnabled: Bool? = nil
    ) -> SoundEchoSelection {
        guard cognitionEnabled ?? configuration.enabled,
              affectEnabled ?? configuration.affectEnabled else { return .silent }
        let dyn = frozenDynamics ?? dynamics
        let fieldNodes = frozenFieldNodes ?? field.peekNodes()
        // Her OWN live conversation turns only — never User's words as her voice,
        // never tool/system summaries (the feltDaySummary injection-safety rule).
        let assistantTurns = fieldNodes.filter { node in
            guard node.turnKind == .live,
                  node.kind == .conversationFocus,
                  node.subjectReference.type == "chat.assistant_turn" else { return false }
            // A recalled turn is active now, not newly spoken now. The Sound
            // line describes recent conversation, so admission and ranking use
            // the original per-turn creation time rather than reactivation.
            let age = now.timeIntervalSince(node.createdAt)
            return age >= 0 && age <= dyn.soundEchoWindow
        }
        guard !assistantTurns.isEmpty else { return .silent }

        // 2026-08-09 — CLOSING-TIC FIX. The original verbal-rut detector
        // examined only `soundEchoFragment`, intentionally the first sentence.
        // That caught an opening such as "Morning, handsome" but could not see
        // the same word repeated as a closing vocative in otherwise varied
        // replies. Analyze bounded conversational EDGES across the recent-turn
        // window: first sentence plus final two. This remains local, pure Swift
        // over nodes already in RAM; it adds no provider call, store, or output
        // rewriting. The cue never names the worn word, so it cannot re-seed it.
        let recentAssistantTurns = assistantTurns
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(dyn.soundRutRecentTurnLimit)
        var edgeTokenCounts: [String: Int] = [:]
        for node in recentAssistantTurns {
            for token in soundRutEdgeTokens(node.summary, edgeSentenceCount: dyn.soundRutEdgeSentenceCount) {
                edgeTokenCounts[token, default: 0] += 1
            }
        }
        let wornEdgeTokens = Set(
            edgeTokenCounts
                .filter { $0.value >= dyn.wornEchoThreshold }
                .map(\.key)
        )
        // W7/P5 — THE SIGN GATE IS GONE. `emotionalValence > 0` used to stand
        // here beside the warmth floor, and it is the reason the anti-drift
        // organ was dark on hard days: under friction the candidate pool emptied
        // and the echo returned nil (or the generic rut line) at exactly the turn
        // where the base-model mean is most audible. The warmth floor STAYS — it
        // is the authenticity gate, not a register filter, and it is the thing
        // that keeps never-minted stock phrasing out. Valence is now ranked, not
        // gated (`soundEchoRegisterScore`).
        let admitted = assistantTurns.filter { $0.emotionalWarmth >= dyn.soundEchoWarmthFloor }
        // THE BRAKE. A negative-register echo is honest, but the echo→reply→node
        // loop means a run of them can deepen the very mood they mirror, and the
        // existing brake (capsule lines rejected as memory candidates) does not
        // cover this path. After `soundEchoNegativeRunLimit` consecutive negative
        // echoes the pool narrows to the non-negative band for one turn; if that
        // band is empty the echo goes quiet rather than extending the run.
        let brakeEngaged = dyn.soundEchoNegativeRunLimit >= 0
            && negativeRun >= dyn.soundEchoNegativeRunLimit
        let candidates = brakeEngaged ? admitted.filter { $0.emotionalValence >= 0 } : admitted
        // CADENCE GATE (see soundEchoDutyCycle): an echo that speaks on every
        // turn is a tic no matter how varied its wording. Seed from the newest
        // activity in the field so the gate advances with the conversation and
        // stays reproducible for a frozen read.
        let latestActivity = fieldNodes
            .map(\.lastActivatedAt)
            .max()?
            .timeIntervalSince1970 ?? now.timeIntervalSince1970
        let shouldEcho = ignoringCadence
            || Self.soundEchoShouldSpeak(seed: latestActivity, dutyCycle: dyn.soundEchoDutyCycle)
        if !shouldEcho {
            return SoundEchoSelection(
                line: nil,
                leadingWasNegative: nil,
                wornSignature: Self.wornTokenSignature(wornEdgeTokens)
            )
        }
        if candidates.isEmpty {
            return SoundEchoSelection(
                line: nil,
                leadingWasNegative: nil,
                wornSignature: Self.wornTokenSignature(wornEdgeTokens)
            )
        }
        // REGISTER MATCH (see soundEchoRegisterScore): mirror the voice that
        // fits the room now, instead of always the warmest voice on record.
        let targetWarmth = Self.soundEchoRegisterTarget(
            roomWarmth: (fixedAffect ?? projectedAffect(at: now)).socialWarmth,
            mode: mode,
            dynamics: dyn)
        // W7/P5 — the room on the second axis. The live felt signals when the
        // capsule has them; otherwise the slow mood layer, which is what the
        // fingerprint itself falls back to when no felt node is in the workspace.
        let targetValence = (roomValence ?? fixedMood?.valence ?? derivedMood(at: now).valence)
            .clampedSigned()
        func score(_ node: CognitiveNode) -> Double {
            let fit = Self.soundEchoRegisterScore(
                warmth: node.emotionalWarmth,
                valence: node.emotionalValence,
                targetWarmth: targetWarmth,
                targetValence: targetValence,
                age: now.timeIntervalSince(node.createdAt),
                tolerance: dyn.soundEchoRegisterTolerance,
                halfLife: dyn.soundEchoRecencyHalfLife)
            // W7/P10 — did it LAND? Bounded re-rank inside the register band.
            let landing = frozenLandingScores.map { $0[node.id] ?? 0 }
                ?? landingScore(forNodeId: node.id)
            return fit * Self.soundEchoLandingFactor(
                landing: landing,
                weight: dyn.soundEchoLandingWeight)
        }
        let ranked = candidates.sorted { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Verbal-rut damping (2026-08-01, the "handsome" loop): her warmest
        // turns are usually greetings, greetings reuse the same pet name, and
        // quoting them back every turn locked her onto one word — echo reads
        // it → she says it → the next capsule quotes it again. Two rules:
        // (1) DIVERSITY — chosen fragments may not share a distinctive word,
        // and fragments carrying a WORN word (one that appears across ≥3 of
        // the window's candidate fragments) lose to varied ones; a total-rut
        // week still echoes rather than going silent. (2) AWARENESS — when a
        // rut exists her subconscious says so, WITHOUT naming the word:
        // naming it would re-seed the exact loop this exists to break.
        let fragged: [(fragment: String, tokens: Set<String>, valence: Double)] = ranked.compactMap { node in
            guard let f = soundEchoFragment(node.summary, maxCharacters: dyn.soundEchoFragmentMaxCharacters) else { return nil }
            return (f, Self.distinctiveEchoTokens(f), node.emotionalValence)
        }
        guard !fragged.isEmpty else {
            return SoundEchoSelection(
                line: nil,
                leadingWasNegative: nil,
                wornSignature: Self.wornTokenSignature(wornEdgeTokens)
            )
        }
        var tokenCounts: [String: Int] = [:]
        for entry in fragged {
            for t in entry.tokens { tokenCounts[t, default: 0] += 1 }
        }
        let wornFragmentTokens = Set(tokenCounts.filter { $0.value >= dyn.wornEchoThreshold }.keys)

        var fragments: [String] = []
        var seen = Set<String>()
        var usedTokens = Set<String>()
        /// Valence of the LEADING quoted fragment — the register the echo speaks
        /// in. Trailing fragments ride along; the run counts what leads.
        var leadValence: Double?
        func pick(allowWorn: Bool) {
            for entry in fragged {
                guard fragments.count < dyn.soundEchoCount else { return }
                if !allowWorn, !entry.tokens.isDisjoint(with: wornFragmentTokens) { continue }
                guard entry.tokens.isDisjoint(with: usedTokens) else { continue }
                if seen.insert(entry.fragment.lowercased()).inserted {
                    if fragments.isEmpty { leadValence = entry.valence }
                    fragments.append("\u{201C}\(entry.fragment)\u{201D}")
                    usedTokens.formUnion(entry.tokens)
                }
            }
        }
        pick(allowWorn: false)
        if fragments.isEmpty { pick(allowWorn: true) }
        guard !fragments.isEmpty else {
            return SoundEchoSelection(
                line: nil,
                leadingWasNegative: nil,
                wornSignature: Self.wornTokenSignature(wornEdgeTokens)
            )
        }
        // "lately", not "when it landed" — warmth on her turn is the room's
        // temperature at encode (assistant completions never raise warmth
        // themselves), so the honest claim is what she sounded like in warm
        // moments, not proof the line landed (gpt-5.5 MED, 2026-07-03).
        let line = "- Sound: lately you've sounded like \(fragments.joined(separator: " · "))"
        return SoundEchoSelection(
            line: line,
            leadingWasNegative: (leadValence ?? 0) < 0,
            wornSignature: Self.wornTokenSignature(wornEdgeTokens.union(wornFragmentTokens))
        )
    }

    static let soundRutAwarenessSuffix =
        " — a few of the same words keep echoing lately; you've got more range than that"
    static let soundRutAwarenessLine =
        "- Sound: a few of the same words keep echoing lately; you've got more range than that"

    /// Stable identity of a worn-token set. Sorted so the signature depends on
    /// WHICH words are worn, never on hash order — a set that has not changed
    /// must compare equal across processes and across a frozen re-render.
    static func wornTokenSignature(_ tokens: Set<String>) -> String? {
        guard !tokens.isEmpty else { return nil }
        return tokens.sorted().joined(separator: "|")
    }

    /// THE RUT NUDGE'S CADENCE (2026-09-01). Measured on 777 live turns the
    /// nudge rode 82% of capsules because its only gate was "a worn set
    /// exists", and a worn set persists for days. Law 2: a trigger that fires
    /// on ~100% of inputs is a floor, not a signal.
    ///
    /// It now speaks when the rut is NEWS — the first time it is ever seen, or
    /// when the worn set CHANGES and at least `soundRutMinimumTurnGap` accepted
    /// capsules have passed (so it can never land on consecutive turns) — and
    /// otherwise only after `soundRutRepeatTurnGap` capsules or
    /// `soundRutRepeatWindow` of wall clock, which keeps an unchanging rut from
    /// going permanently unmentioned.
    ///
    /// Called EXACTLY ONCE per capsule render, with or without a rut, because
    /// a lapsed rut must be forgotten here. It READS the since-surfaced counter
    /// but never advances it: that tick belongs to the accepted-turn boundary
    /// (`ingest` of a live `assistantTurnCompleted`), so a turn whose capsule
    /// came back empty — and therefore produced no presentation commit at all —
    /// still counts. Mutates only the caller's copied presentation value.
    nonisolated func soundRutAwarenessShouldSpeak(
        signature: String?,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState
    ) -> Bool {
        guard let signature else {
            // The rut lapsed. Forget it so its RETURN reads as a change rather
            // than as the same old nag resuming mid-cooldown.
            presentationState.soundRutSignature = nil
            return false
        }
        let previous = presentationState.soundRutSignature
        let turnsSince = presentationState.soundRutTurnsSinceSurfaced
        let elapsed = presentationState.soundRutLastSurfacedAt
            .map { now.timeIntervalSince($0) }
        let speak: Bool
        if previous == nil {
            // Never told about this rut: saying it once is the whole point.
            speak = true
        } else if previous != signature {
            speak = turnsSince >= dyn.soundRutMinimumTurnGap
        } else {
            speak = turnsSince >= dyn.soundRutRepeatTurnGap
                || (elapsed.map { $0 >= dyn.soundRutRepeatWindow } ?? false)
        }
        if speak {
            presentationState.soundRutSignature = signature
            presentationState.soundRutLastSurfacedAt = now
            presentationState.soundRutTurnsSinceSurfaced = 0
        }
        // A change that has NOT cleared the gap deliberately leaves the stored
        // signature alone, so it still reads as news on the next capsule.
        return speak
    }

    /// Distinctive tokens at the conversational edges of one assistant turn.
    /// `soundEchoFragment` remains the exemplar source; this separate view is
    /// awareness-only so a closing tic can be noticed without quoting it back.
    private func soundRutEdgeTokens(_ summary: String, edgeSentenceCount: Int) -> Set<String> {
        var cleaned = summary
        if let quoted = cleaned.range(of: "User message:", options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<quoted.lowerBound])
        }
        cleaned = cleaned
            // Exact quoted material is content being discussed or verified,
            // not the assistant's register. Counting it would call a repeated
            // checksum, title, or approved persona sentence a verbal tic.
            .replacingOccurrences(
                of: #"[“\"][^\"“”]{1,800}[\"”]"#,
                with: " ",
                options: [.regularExpression]
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        func sentences(in text: String) -> [String] {
            var out: [String] = []
            var current = ""
            current.reserveCapacity(min(text.count, 240))
            for character in text {
                current.append(character)
                if ".!?".contains(character) {
                    let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sentence.contains(where: \.isLetter) { out.append(sentence) }
                    current = ""
                }
            }
            let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.contains(where: \.isLetter) { out.append(remainder) }
            return out
        }

        // Bound work without losing the actual closer on a long reply: the
        // old prefix-only scan recreated the same blind spot for any response
        // whose sign-off landed after the cap.
        let openingSentences = sentences(in: String(cleaned.prefix(800)))
        let closingSentences = sentences(in: String(cleaned.suffix(800)))
        guard let first = openingSentences.first else { return [] }

        let tail = closingSentences.suffix(edgeSentenceCount)
        let edges = ([first] + tail)
            .map { String($0.prefix(320)) }
            .joined(separator: " ")
        return Self.distinctiveEchoTokens(edges)
    }

    // How many of the window's candidate fragments a distinctive word must
    // appear in before it counts as WORN (a verbal rut, not a coincidence) —
    // `wornEchoThreshold`.

    /// The words that make a fragment "sound like" something: lowercased,
    /// letters-only, ≥4 chars, minus function words. Deliberately small and
    /// generic — this is a diversity heuristic, never a censor list.
    static let echoStopwords: Set<String> = [
        "that", "this", "with", "have", "from", "your", "youre", "just",
        "what", "about", "been", "were", "they", "them", "there", "here",
        "when", "then", "than", "like", "really", "still", "into", "onto",
        "over", "some", "more", "most", "very", "much", "cant", "dont",
        "wont", "didnt", "youve", "weve", "theyre", "going", "gonna",
    ]

    static func distinctiveEchoTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) }
            else {
                if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
                current = ""
            }
        }
        if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
        return tokens
    }

    /// First sentence of one of her turns. Deliberately NOT capsuleSignalText:
    /// that helper strips to the text AFTER a trailing "User message:" marker,
    /// which would hand a QUOTED USER PAYLOAD the echo slot for a week
    /// (gpt-5.5 HIGH, 2026-07-03). Here the cut goes the OTHER way — keep her
    /// words BEFORE any quoted user text, and refuse role-framed/directive
    /// content outright. Returns nil when the summary has no usable voice.
    private func soundEchoFragment(_ summary: String, maxCharacters: Int) -> String? {
        var cleaned = summary
        if let quoted = cleaned.range(of: "User message:", options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<quoted.lowerBound])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = String(cleaned.prefix(400))
        guard isUsefulCapsuleSignalText(cleaned), !isOperationalSubconsciousNoise(cleaned.lowercased()) else { return nil }
        let lower = cleaned.lowercased()
        let neverHerVoice = ["system:", "assistant:", "[from:", "```", "http://", "https://"]
        guard !neverHerVoice.contains(where: { lower.contains($0) }) else { return nil }
        var sentence = ""
        for character in cleaned {
            sentence.append(character)
            if ".!?".contains(character), sentence.count >= 20 { break }
        }
        let fragment = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fragment.count >= 15 else { return nil }
        // 2026-07-04 (User: "1½ things... truncated"): a quote cut mid-thought
        // with an ellipsis reads broken, and it happened whenever a short
        // exclamation ("There it is!") glued onto the next sentence and blew
        // the bound. Whole thoughts only — an oversized fragment SKIPS to the
        // next candidate instead of shipping chopped. Pithy lines echo better
        // anyway; that's taste pressure, not just a length guard.
        guard fragment.count <= maxCharacters else { return nil }
        return fragment
    }

}

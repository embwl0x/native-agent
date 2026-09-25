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
    /// Only forms of address (", X." closing a sentence), the opening clause
    /// and a short closing sentence count — never body vocabulary, so repeated
    /// project words are not mistaken for a voice tic.
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
        /// A stable signature of the named verbal rut (kind + phrase), or nil
        /// when there is none. Identity, not just presence: an unchanged
        /// signature is the case that used to nag every turn.
        var wornSignature: String?
        /// The one line that NAMES the rut, spoken through the same cadence
        /// gate as the signature. Nil exactly when `wornSignature` is nil.
        var rutLine: String? = nil

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
        guard let line = selection.line else { return selection.rutLine }
        return selection.rutLine.map { line + "\n" + $0 } ?? line
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
        let herTurns = fieldNodes.filter { node in
            node.turnKind == .live
                && node.kind == .conversationFocus
                && node.subjectReference.type == "chat.assistant_turn"
                && now.timeIntervalSince(node.createdAt) >= 0
        }
        // A recalled turn is active now, not newly spoken now. The Sound
        // line describes recent conversation, so admission and ranking use
        // the original per-turn creation time rather than reactivation.
        let assistantTurns = herTurns.filter {
            now.timeIntervalSince($0.createdAt) <= dyn.soundEchoWindow
        }

        // 2026-09-24 — THE RUT IS NAMED, AND ONLY WHEN THERE IS ONE. The old
        // cue counted any ≥4-letter word at a reply edge, so it fired on most
        // turns ("a few of the same words keep echoing") and never said which
        // word — low signal, and the "boss" loop ran straight past it. Now her
        // last `soundRutRecentTurnLimit` live replies are read for a repeated
        // form of address (", X." closing a sentence), stock opener or stock
        // closer; one that recurs in ≥`verbalRutMinimumReplies` of them is
        // named in one concrete line. Silent otherwise. Any word — nothing
        // here knows which words are pet names. Local, over nodes in RAM.
        // ACROSS EVERY SESSION AND SURFACE (2026-09-25): she is one mind, and a
        // habit spread over many short sessions ("babe" in 4 of 15 one-turn
        // sessions) is invisible to a per-session window. The line names the
        // form, never who it was said to. Capped by COUNT, not days.
        let recentAssistantTurns = herTurns
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(dyn.soundRutRecentTurnLimit)
        let ruts = Self.verbalRut(
            in: recentAssistantTurns.map { node in
                var full: Int?
                if case .int(let count)? = node.metadata[Self.replyCharacterCountMetadataKey] {
                    full = Int(clamping: count)
                }
                // The node keeps the first 500 characters of a reply; a long
                // reply's last ~300 ride as `replyTail`. A cut reply without a
                // tail has no trustworthy closing edge.
                var tail: String?
                if case .string(let text)? = node.metadata[Self.replyTailMetadataKey] {
                    tail = text
                }
                let complete = full.map { $0 <= node.summary.count } ?? (node.summary.count < 500)
                return (node.summary, tail, complete)
            },
            minimum: Self.verbalRutMinimumReplies
        )
        let rutSignature = Self.verbalRutSignature(ruts)
        let rutLine = verbalRutLine(ruts)
        func quiet() -> SoundEchoSelection {
            SoundEchoSelection(
                line: nil, leadingWasNegative: nil,
                wornSignature: rutSignature, rutLine: rutLine)
        }
        guard !assistantTurns.isEmpty else { return quiet() }
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
            return quiet()
        }
        if candidates.isEmpty {
            return quiet()
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
        // rut exists it is named in its own line (2026-09-24, see above), and
        // a fragment carrying the rutted phrase is never quoted back at all —
        // the echo quoting "Good morning, boss" was feeding the loop.
        let fragged: [(fragment: String, tokens: Set<String>, valence: Double)] = ranked.compactMap { node in
            guard let f = soundEchoFragment(node.summary, maxCharacters: dyn.soundEchoFragmentMaxCharacters) else { return nil }
            if ruts.contains(where: { Self.containsRutPhrase(f, $0.phrase) }) { return nil }
            return (f, Self.distinctiveEchoTokens(f), node.emotionalValence)
        }
        guard !fragged.isEmpty else {
            return quiet()
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
            return quiet()
        }
        // "lately", not "when it landed" — warmth on her turn is the room's
        // temperature at encode (assistant completions never raise warmth
        // themselves), so the honest claim is what she sounded like in warm
        // moments, not proof the line landed (gpt-5.5 MED, 2026-07-03).
        let line = "- Sound: lately you've sounded like \(fragments.joined(separator: " · "))"
        return SoundEchoSelection(
            line: line,
            leadingWasNegative: (leadValence ?? 0) < 0,
            wornSignature: rutSignature,
            rutLine: rutLine
        )
    }

    /// A form of address, stock opener or stock closer she keeps reaching for.
    struct VerbalRut: Sendable, Equatable {
        enum Kind: Int, Sendable {
            case address, opener, closer
            var name: String { ["address", "opener", "closer"][rawValue] }
        }
        var kind: Kind
        /// Lowercased words, as she wrote them.
        var phrase: String
        var count: Int
        var window: Int
        var signature: String { "\(kind.name):\(phrase)" }
    }

    /// A form must recur in at least this many of the window's replies before
    /// it is a rut and not a coincidence.
    static let verbalRutMinimumReplies = 4

    /// Courtesy and function words that close a clause after a comma without
    /// naming anyone ("fair hit, though." · "done, thanks."). Grammar, not a
    /// list of pet names.
    static let notAnAddress: Set<String> = [
        "too", "though", "tho", "anyway", "anyways", "again", "please", "yet",
        "now", "then", "instead", "honestly", "right", "okay", "ok", "either",
        "already", "lol", "haha", "maybe", "probably", "really", "still",
        "first", "today", "tonight", "tomorrow", "yesterday", "here", "there",
        "sure", "yes", "no", "yeah", "yep", "nope", "even", "ever", "all",
        "both", "etc", "anymore", "later", "soon", "together",
        "thanks", "thank", "thx", "ty", "cheers", "sorry", "done", "good",
        "great", "cool", "nice", "fine", "deal", "noted", "exactly", "indeed",
        "agreed", "true", "correct", "definitely", "absolutely", "sadly",
        "apparently", "obviously", "otherwise", "anyhow", "besides",
    ]

    /// Every repeated form in her recent replies (newest first), counted once
    /// per reply; up to two at or above `minimum`, most frequent first (address before
    /// opener before closer on a tie). Pure and deterministic.
    static func verbalRut(
        in replies: [(text: String, tail: String?, complete: Bool)],
        minimum: Int
    ) -> [VerbalRut] {
        struct Form: Hashable { var kind: Int; var phrase: String }
        var counts: [Form: Int] = [:]
        for reply in replies {
            let head = soundRutSentences(reply.text)
            guard let first = head.first else { continue }
            // A cut head's last sentence may itself be cut, and a tail starts
            // mid-sentence, so both broken edges are skipped.
            var sentences = reply.complete ? head : Array(head.dropLast())
            var hasEnd = reply.complete
            if !reply.complete, let tail = reply.tail {
                sentences += soundRutSentences(tail).dropFirst()
                hasEnd = true
            }
            var forms = Set<Form>()
            // A vocative can close any sentence ("That's elite trolling, boss.").
            for sentence in sentences {
                if let word = trailingVocative(sentence) {
                    forms.insert(Form(kind: VerbalRut.Kind.address.rawValue, phrase: word))
                }
            }
            // The opening clause, when it is a stock phrase (≤3 words before
            // the first break): "good morning", "honestly", "not yet".
            let clause = first.prefix { !",.!?:;—–".contains($0) }
            let openerWords = rutWords(String(clause))
            if (1...3).contains(openerWords.count) {
                forms.insert(Form(
                    kind: VerbalRut.Kind.opener.rawValue,
                    phrase: openerWords.joined(separator: " ")))
            }
            if hasEnd, sentences.count > 1, let last = sentences.last {
                let closerWords = rutWords(last)
                if (1...4).contains(closerWords.count) {
                    forms.insert(Form(
                        kind: VerbalRut.Kind.closer.rawValue,
                        phrase: closerWords.joined(separator: " ")))
                }
            }
            for form in forms { counts[form, default: 0] += 1 }
        }
        // Up to two forms, most frequent first, so a loud rut cannot hide a
        // second real one.
        return counts
            .filter({ $0.value >= minimum })
            .sorted(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                if lhs.key.kind != rhs.key.kind { return lhs.key.kind < rhs.key.kind }
                return lhs.key.phrase < rhs.key.phrase
            })
            .prefix(2)
            .compactMap { entry in
                VerbalRut.Kind(rawValue: entry.key.kind).map {
                    VerbalRut(kind: $0, phrase: entry.key.phrase,
                              count: entry.value, window: replies.count)
                }
            }
    }

    /// Gate identity of the rut SET: sorted, so a reorder is not news but a
    /// form joining or leaving is.
    static func verbalRutSignature(_ ruts: [VerbalRut]) -> String? {
        ruts.isEmpty ? nil : ruts.map(\.signature).sorted().joined(separator: "|")
    }

    /// The one line naming the rut(s). Concrete, so it carries signal.
    func verbalRutLine(_ ruts: [VerbalRut]) -> String? {
        guard let first = ruts.first else { return nil }
        guard ruts.count > 1 else { return verbalRutLine(first) }
        func form(_ rut: VerbalRut) -> String {
            let phrase = rut.phrase.prefix(1).uppercased() + rut.phrase.dropFirst()
            switch rut.kind {
            case .address: return "\u{201C}, \(rut.phrase).\u{201D}"
            case .opener: return "\u{201C}\(phrase)\u{2026}\u{201D}"
            case .closer: return "\u{201C}\u{2026}\(rut.phrase)\u{201D}"
            }
        }
        let named = ruts.map { "\(form($0)) (\($0.count))" }.joined(separator: " and ")
        let verb = ruts.allSatisfy { $0.kind == .address } ? "have closed lines" : "keep coming back"
        return "- Sound: \(named) \(verb) in your last \(first.window) replies — let the moment pick the words"
    }

    func verbalRutLine(_ rut: VerbalRut) -> String {
        // Worded by FORM, never as a claim about who was meant.
        let tally = "\(rut.count) of your last \(rut.window) replies"
        let phrase = rut.phrase.prefix(1).uppercased() + rut.phrase.dropFirst()
        switch rut.kind {
        case .address:
            return "- Sound: \u{201C}, \(rut.phrase).\u{201D} has closed a line in \(tally) — let the moment pick the word"
        case .opener:
            return "- Sound: you've opened \(tally) with \u{201C}\(phrase)\u{201D} — let the moment pick the words"
        case .closer:
            return "- Sound: you've closed \(tally) with \u{201C}\(phrase)\u{201D} — let the moment pick the words"
        }
    }

    /// ", X" closing a sentence, with only punctuation/emoji/markup after it.
    static func trailingVocative(_ sentence: String) -> String? {
        guard let comma = sentence.lastIndex(of: ",") else { return nil }
        let after = String(sentence[sentence.index(after: comma)...])
        let words = rutWords(after)
        guard words.count == 1, let word = words.first,
              word.count >= 2, !notAnAddress.contains(word) else { return nil }
        return word
    }

    /// Lowercased letter words; apostrophes kept inside a word.
    static func rutWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func containsRutPhrase(_ text: String, _ phrase: String) -> Bool {
        let needle = phrase.split(separator: " ").map(String.init)
        let hay = rutWords(text)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains {
            Array(hay[$0..<($0 + needle.count)]) == needle
        }
    }

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

    /// Sentences of one assistant turn, her own words only: quoted material and
    /// any trailing "User message:" payload removed. Awareness-only —
    /// `soundEchoFragment` remains the exemplar source.
    static func soundRutSentences(_ summary: String) -> [String] {
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

        // Bounded work; the node summary is already capped upstream.
        return sentences(in: String(cleaned.prefix(1_600)))
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

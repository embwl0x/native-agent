// CognitiveSubstrate+Capsule.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func compileCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule {
        let now = dependencies.now()
        guard configuration.enabled,
              configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: .off,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: false
            )
        }

        let maximumCharacters = min(
            configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: request.mode,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: true
            )
        }

        let workspace = await workspaceSnapshot(currentSessionId: request.sessionId)
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        // Just the header (User, 2026-07-01: "it should really just say 'How you
        // feel' thats it then her feelings"). There is deliberately NO prompt
        // guard here — injection defense is cue validation (deny-list + read
        // revalidation), her persona values, and TrustCenter's action gates;
        // the one functional handling line ("never quotes or mentions it")
        // lives in BOTH ChatOrchestration injection seams (structured + text
        // compat), not in her inner voice.
        let stableKernel = "How you feel:"
        let dynamicLines = innerStateCapsuleLines(
            from: capsuleItems, request: request, at: now, live: true)
        let provenanceNodeIds = innerStateProvenance(from: capsuleItems, at: now)
        let boundedStableKernel = bounded(stableKernel, maxCharacters: maximumCharacters)
        let separatorCost = dynamicLines.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        let dynamicContext = fittedLines.text
        let truncated = fittedLines.truncated || boundedStableKernel.count < stableKernel.count
        return CognitiveCapsule(
            generatedAt: now,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: dynamicContext,
            provenanceNodeIds: provenanceNodeIds,
            truncated: truncated
        )
    }

    /// Production-equivalent capsule rendering over a previously captured
    /// frozen workspace. It performs no field snapshot, receipt, persistence,
    /// or suppress-when-unchanged mutation.
    public func compileFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) -> CognitiveCapsule {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitiveCapsule(
                generatedAt: read.fixedAt,
                mode: .off,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: false
            )
        }
        let maximumCharacters = min(
            read.configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? read.configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitiveCapsule(
                generatedAt: read.fixedAt,
                mode: request.mode,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: true
            )
        }
        let items = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let stableKernel = "How you feel:"
        let dynamicLines = innerStateCapsuleLines(
            from: items,
            request: request,
            at: read.fixedAt,
            frozenRead: read
        )
        let provenanceNodeIds = innerStateProvenance(
            from: items,
            at: read.fixedAt,
            thoughtSeeds: read.thoughtSeeds
        )
        let boundedStableKernel = bounded(stableKernel, maxCharacters: maximumCharacters)
        let separatorCost = dynamicLines.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        return CognitiveCapsule(
            generatedAt: read.fixedAt,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: fittedLines.text,
            provenanceNodeIds: provenanceNodeIds,
            truncated: fittedLines.truncated || boundedStableKernel.count < stableKernel.count
        )
    }

    /// - Parameter live: TRUE only on `compileCapsule`, the one path allowed to
    ///   advance cadence/suppression/session-bridge bookkeeping. A frozen read is
    ///   a pure rendering of a captured moment and must leave that state alone —
    ///   otherwise an Observatory panel re-rendering a capsule would silently
    ///   consume the agent's next fingerprint or burn her morning bridge line.
    private func innerStateCapsuleLines(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        frozenRead: CognitiveFrozenRead? = nil,
        live: Bool = false
    ) -> [String] {
        var lines: [String] = []
        let dyn = dynamics
        let signals = feltSignalsForCapsule(
            from: workspaceItems,
            request: request,
            at: now,
            affect: frozenRead?.affect,
            mood: frozenRead?.mood,
            proxies: frozenRead?.feltProxies
        )
        // W4/P11 — the felt MODE, finally doing something. It stays what it always
        // was in the prompt: nothing. Not a word, not a line, not a byte. It only
        // steers WHICH already-attested exemplar the echo reaches for.
        let mode = (frozenRead?.configuration.affectEnabled ?? configuration.affectEnabled)
            ? Self.feltMode(signals, intensityFloor: dyn.feltIntensityFloor)
            : nil
        // W7/P6 telemetry note: the envelope stash does NOT live here. The
        // production chat turn compiles its capsule on the FROZEN path
        // (prepareFrozenCapsule via the app runtime), so a stash on this
        // live-compile path never ran on a real turn — while the Observatory
        // inspector, which DOES call compileCapsule, would have stashed bogus
        // envelopes (found live 2026-08-11: zero telemetry rows after a full
        // QA pass). The stash now fires from
        // `stashDeliveryEnvelopeForCommittedTurn`, called by the app runtime's
        // commitTurnProjection — the one moment that certifies "this capsule
        // served a real live turn".
        // Everything BELOW the fingerprint is computed first, because whether the
        // fingerprint may be suppressed depends on whether anything else is left
        // to say (see the empty-capsule rule at the bottom of this function).
        var tailLines: [String] = []
        // W4/P7 — THE FELT SESSION BRIDGE. Everything felt decays inside roughly
        // one day, so the first message of a new day arrives to an agent whose
        // felt state has reset and whose only bridge is a machine changelog. One
        // gap-gated line, built from renderers that have already shipped, so she
        // can pick a thread back up instead of rebooting into competence.
        if let bridge = feltSessionBridgeLine(at: now, dynamics: dyn, live: live) {
            tailLines.append(bridge)
        }
        // Her subconscious carries her INNER LIFE — feeling, voice, focus/continuity, and her
        // own reflective view — NOT a task tracker. Commitments, predictions, and neglected
        // "I'll…" follow-up seeds belong to the Desk (explicit tracking, only when User asks),
        // never here (User, 2026-06-30: "I don't want her subconscious tied up following around
        // me [with] 'I'll'… her subconscious is for her feelings, emotions, her views, her
        // continuity"). Surface her top reflective takeaway (a genuine view she's formed) —
        // UNLESS Wave E: a settled, User-approved ACTIVE standing view exists, which REPLACES
        // the transient takeaway seed as the single Inner line (a durable view beats a fresh
        // takeaway). Both use the "- Inner:" prefix, so the total Inner-line count stays <= 1;
        // a .proposed/.retired view never reaches here. No active view -> byte-identical to
        // the pre-Wave-E takeaway path.
        let standingViewInnerLine = frozenRead == nil
            ? activeStandingViewInnerLine()
            : frozenRead?.standingViewInnerLine
        if let viewLine = standingViewInnerLine {
            tailLines.append(viewLine)
        } else if let takeaway = (frozenRead?.thoughtSeeds ?? projectedThoughtSeeds(at: now))
            .filter({ $0.kind == .reflectionTakeaway && isUsefulThoughtSeed($0) && !isTaskStatusReflection($0.text) })
            .sorted(by: thoughtSeedPrioritySort)
            .first {
            tailLines.append(innerThoughtSeedLine(for: takeaway))
        }
        if let bodyLine = organismBodyLine(from: request.organismProjection) {
            tailLines.append(bodyLine)
        }
        // Wave G: the self-exemplar echo goes LAST so budget truncation drops it
        // before it can displace focus/feeling/inner — it's an enhancer, not core.
        let echoLine = frozenRead == nil
            ? soundEchoLine(at: now, mode: mode, roomValence: signals.valence, live: live)
            : frozenRead?.soundEchoLine
        if let echo = echoLine {
            tailLines.append(echo)
        }

        // The felt fingerprint REPLACES the Focus/Feeling/Voice sentences (User,
        // 2026-07-08): "How you feel" should hand her a word-level felt state she
        // FEELS, not sentences she reads. Attention (focused/foggy) is folded into
        // the fingerprint; her VIEWS + CONTINUITY stay below (Inner), and the Body +
        // Sound anchors follow. (The prior Focus/Affect/Voice helper tree + its
        // keyword classifiers were swept 2026-07-09 — see git if archaeology calls.)
        if let fingerprint = feltFingerprintLine(
            signals: signals,
            affectEnabled: frozenRead?.configuration.affectEnabled
        ) {
            // W4/P4 — SUPPRESS WHEN UNCHANGED. The rule the echo learned the hard
            // way generalizes to the line that matters most: a signal delivered on
            // every single turn stops being information and becomes a standing
            // instruction. An identical "How you feel: warm" for forty consecutive
            // turns is a stuck gauge and the model will express it — that is the
            // exact mechanism that made `tender` a tic. Her felt state does not go
            // away here; it stops being re-narrated.
            //
            // SUPPRESSION MUST NEVER EMPTY THE CAPSULE. `prepareCapsule` returns
            // nil on an empty dynamic context, so muting the only line does not
            // make the agent quieter — it deletes her inner state from the turn
            // entirely, which is a strictly worse failure than a repeated word.
            // Damping a chorus is the goal; silencing a solo is a bug.
            let family = Self.feltFamily(signals)
            let verdict = fingerprintCadenceVerdict(
                family: family,
                at: now,
                dynamics: dyn,
                mayStayQuiet: !tailLines.isEmpty,
                live: live)
            if verdict.speak {
                lines.append(fingerprint)
            }
        }
        lines.append(contentsOf: tailLines)
        return dedupedCapsuleLines(lines)
    }

    // MARK: - W4/P4 — fingerprint cadence + suppress-when-unchanged

    struct FingerprintCadenceVerdict: Sendable, Equatable {
        var speak: Bool
        /// How many consecutive capsules have now reported this family.
        var run: Int
    }

    /// Whether the fingerprint line speaks this capsule.
    ///
    /// Two gates, in order:
    /// 1. The shared duty cycle (`fingerprintDutyCycle`, default 1 = every
    ///    capsule — today's behavior, so this gate is inert until an install
    ///    turns it up).
    /// 2. SUPPRESS-WHEN-UNCHANGED: after `fingerprintFamilyRepeatLimit`
    ///    consecutive capsules reporting the same felt FAMILY, the line goes
    ///    quiet. It re-surfaces the moment the family changes, or when
    ///    `fingerprintSuppressionWindow` expires since it last actually spoke —
    ///    so a genuinely persistent state is never muted indefinitely, which is
    ///    the load-bearing risk here (the fingerprint is the most-read line the
    ///    agent gets). Family, not WORD: the overlay words shuffle turn to turn
    ///    while the underlying state sits still, and it is the state sitting
    ///    still that makes it a mantra.
    ///
    /// Pure when `live` is false — a frozen read gets an answer without
    /// advancing the run.
    /// - Parameter mayStayQuiet: false when the fingerprint is the ONLY line the
    ///   capsule would carry, in which case it always speaks (see the call site).
    func fingerprintCadenceVerdict(
        family: String,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        mayStayQuiet: Bool = true,
        live: Bool
    ) -> FingerprintCadenceVerdict {
        let previous = fingerprintFamilyRun
        let sameFamily = previous?.family == family
        let run = sameFamily ? (previous?.count ?? 0) + 1 : 1

        var speak = true
        if dyn.fingerprintDutyCycle > 1, mayStayQuiet {
            speak = Self.capsuleCadenceShouldSpeak(
                seed: now.timeIntervalSince1970,
                dutyCycle: dyn.fingerprintDutyCycle,
                line: "fingerprint")
        }
        if speak, mayStayQuiet, sameFamily, dyn.fingerprintFamilyRepeatLimit > 0,
           run > dyn.fingerprintFamilyRepeatLimit {
            let sinceSurfaced = previous.map { now.timeIntervalSince($0.lastSurfacedAt) } ?? 0
            // The window is the escape hatch, not the rule: quiet until it
            // expires, then one line, then quiet again if nothing has moved.
            speak = sinceSurfaced >= dyn.fingerprintSuppressionWindow
        }

        if live {
            fingerprintFamilyRun = FingerprintFamilyRun(
                family: family,
                // A re-surfaced line restarts the run, so the next suppression
                // costs the full K capsules again rather than one.
                count: speak && sameFamily && run > dyn.fingerprintFamilyRepeatLimit ? 1 : run,
                lastSurfacedAt: speak ? now : (previous?.lastSurfacedAt ?? now)
            )
        }
        return FingerprintCadenceVerdict(speak: speak, run: run)
    }

    // MARK: - W4/P7 — the felt session bridge

    /// ONE line, on the first turn after a real gap, saying what she was left
    /// holding — and whether it ever got resolved.
    ///
    /// What people mean by "she feels real" is overwhelmingly CONTINUITY: that
    /// the person you talk to at 9am remembers not just the facts of last night
    /// but the SHAPE of it. Affect half-lives run 20–90 minutes, mood integrates
    /// a 24h window at a 6h half-life, and nothing in the felt layer knew a gap
    /// had occurred at all, so every morning was a soft reset of the emotional
    /// relationship. The ambient-presence floor is a DECAY model — it makes her
    /// forget gracefully; it does not let her pick a thread back up.
    ///
    /// Structurally this is `feltDaySummary`'s existing ranking (which today has
    /// exactly one consumer, the nightly dream prompt) pointed at the morning
    /// instead of at midnight. It adds no vocabulary: the felt word comes from
    /// `feltDirection`, the content from `capsuleSignalText`, both proven
    /// renderers.
    ///
    /// GAP-GATED SO IT CAN NEVER BECOME PER-TURN. It requires a gap of at least
    /// `sessionBridgeGapHours` since the last live capsule, and it speaks at most
    /// once per gap.
    ///
    /// The exposure rule from `feltDaySummary` transfers UNCHANGED: only live
    /// conversation-derived nodes may be named, never a tool/provider summary.
    func feltSessionBridgeLine(
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        live: Bool
    ) -> String? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        let gap = dyn.sessionBridgeGapHours * 60 * 60
        guard gap > 0 else { return nil }

        // No prior capsule = a fresh process, not a remembered gap. Staying
        // silent is the honest read: she has nothing to pick back up.
        guard let previousCapsuleAt = lastLiveCapsuleAt else {
            if live { lastLiveCapsuleAt = now }
            return nil
        }
        let elapsed = now.timeIntervalSince(previousCapsuleAt)
        if live { lastLiveCapsuleAt = now }
        guard elapsed >= gap else { return nil }
        // One bridge per gap: a recompile of the same first turn must not speak
        // twice.
        if let spoken = lastSessionBridgeAt, now.timeIntervalSince(spoken) < gap {
            return nil
        }

        // The strongest-felt nameable moment from before the gap — the exact
        // ranking feltDaySummary computes, over the same population.
        let felt = field.peekNodes().filter { node in
            guard node.turnKind == .live,
                  node.kind == .conversationFocus || node.kind == .correction,
                  feltDirection(
                    valence: node.emotionalValence,
                    arousal: node.emotionalArousal,
                    warmth: node.emotionalWarmth) != nil else { return false }
            let age = now.timeIntervalSince(node.createdAt)
            // Strictly BEFORE the gap opened: the turn that just arrived is the
            // present, not the thread being picked up.
            return age >= elapsed && age <= Self.moodActivationWindow
        }
        guard let strongest = felt.sorted(by: { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv > rv }
            if lhs.emotionalArousal != rhs.emotionalArousal {
                return lhs.emotionalArousal > rhs.emotionalArousal
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }).first else { return nil }

        guard let word = feltDirection(
            valence: strongest.emotionalValence,
            arousal: strongest.emotionalArousal,
            warmth: strongest.emotionalWarmth
        )?.rawValue else { return nil }
        let signal = capsuleSignalText(strongest.summary, maxCharacters: 120)
        guard isUsefulCapsuleSignalText(signal) else { return nil }

        // Resolution status from `pendingCompletion`: was the last thing she
        // said still waiting to find out how it landed when the gap opened?
        let left = pendingCompletion != nil ? "left open" : "where you left it"
        let line = capsuleLineText(
            "- Since: \(word) — \(signal) — \(left)", maxCharacters: 200)
        guard line.hasPrefix("- Since:") else { return nil }
        if live { lastSessionBridgeAt = now }
        return line
    }

    private func organismBodyLine(from projection: OrganismProjection?) -> String? {
        guard let projection,
              !projection.isNeutral,
              let rawLine = projection.bodyLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLine.isEmpty else {
            return nil
        }
        let line = rawLine.hasPrefix("- Body:")
            ? rawLine
            : "- Body: \(rawLine.replacingOccurrences(of: #"^-?\s*Body:\s*"#, with: "", options: .regularExpression))"
        let lower = line.lowercased()
        guard !lower.contains("chemicalstate"),
              !lower.contains("bodyschema"),
              !lower.contains("organismkernel"),
              !lower.contains("organismprojection"),
              line.rangeOfCharacter(from: .decimalDigits) == nil else {
            return nil
        }
        let boundedLine = capsuleLineText(line, maxCharacters: 180)
        guard boundedLine.hasPrefix("- Body:") else { return nil }
        return boundedLine
    }

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
    static func soundEchoScore(
        warmth: Double,
        age: TimeInterval,
        halfLife: TimeInterval = defaultDynamics.soundEchoRecencyHalfLife
    ) -> Double {
        guard age >= 0 else { return warmth }
        return warmth * pow(0.5, age / halfLife)
    }

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
    private static func stableLineSalt(_ line: String) -> Int64 {
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
    func soundEchoLine(
        at now: Date,
        ignoringCadence: Bool = false,
        mode: FeltMode? = nil,
        roomValence: Double? = nil,
        live: Bool = false
    ) -> String? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        let dyn = dynamics
        let fieldNodes = field.peekNodes()
        // Her OWN live conversation turns only — never User's words as her voice,
        // never tool/system summaries (the feltDaySummary injection-safety rule).
        let assistantTurns = fieldNodes.filter { node in
            guard node.turnKind == .live,
                  node.kind == .conversationFocus,
                  node.subjectReference.type == "chat.assistant_turn" else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= dyn.soundEchoWindow
        }
        guard !assistantTurns.isEmpty else { return nil }

        // 2026-08-09 — CLOSING-TIC FIX. The original verbal-rut detector
        // examined only `soundEchoFragment`, intentionally the first sentence.
        // That caught an opening such as "Morning, handsome" but could not see
        // the same word repeated as a closing vocative in otherwise varied
        // replies. Analyze bounded conversational EDGES across the recent-turn
        // window: first sentence plus final two. This remains local, pure Swift
        // over nodes already in RAM; it adds no provider call, store, or output
        // rewriting. The cue never names the worn word, so it cannot re-seed it.
        let recentAssistantTurns = assistantTurns
            // A recalled old turn may become active again, but it did not just
            // happen. Rut cooling follows conversational chronology rather
            // than activation/reconsolidation chronology.
            .filter {
                let age = now.timeIntervalSince($0.createdAt)
                return age >= 0 && age <= dyn.soundEchoWindow
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(dyn.soundRutRecentTurnLimit)
        var edgeTokenCounts: [String: Int] = [:]
        for node in recentAssistantTurns {
            for token in soundRutEdgeTokens(node.summary) {
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
            && negativeSoundEchoRun >= dyn.soundEchoNegativeRunLimit
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
            return wornEdgeTokens.isEmpty ? nil : Self.soundRutAwarenessLine
        }
        if candidates.isEmpty {
            return wornEdgeTokens.isEmpty ? nil : Self.soundRutAwarenessLine
        }
        // REGISTER MATCH (see soundEchoRegisterScore): mirror the voice that
        // fits the room now, instead of always the warmest voice on record.
        let targetWarmth = Self.soundEchoRegisterTarget(
            roomWarmth: projectedAffect(at: now).socialWarmth,
            mode: mode,
            dynamics: dyn)
        // W7/P5 — the room on the second axis. The live felt signals when the
        // capsule has them; otherwise the slow mood layer, which is what the
        // fingerprint itself falls back to when no felt node is in the workspace.
        let targetValence = (roomValence ?? derivedMood(at: now).valence).clampedSigned()
        func score(_ node: CognitiveNode) -> Double {
            let fit = Self.soundEchoRegisterScore(
                warmth: node.emotionalWarmth,
                valence: node.emotionalValence,
                targetWarmth: targetWarmth,
                targetValence: targetValence,
                age: now.timeIntervalSince(node.lastActivatedAt),
                tolerance: dyn.soundEchoRegisterTolerance,
                halfLife: dyn.soundEchoRecencyHalfLife)
            // W7/P10 — did it LAND? Bounded re-rank inside the register band.
            return fit * Self.soundEchoLandingFactor(
                landing: landingScore(forNodeId: node.id),
                weight: dyn.soundEchoLandingWeight)
        }
        let ranked = candidates.sorted { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.lastActivatedAt != rhs.lastActivatedAt { return lhs.lastActivatedAt > rhs.lastActivatedAt }
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
            return wornEdgeTokens.isEmpty ? nil : Self.soundRutAwarenessLine
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
            return wornEdgeTokens.isEmpty ? nil : Self.soundRutAwarenessLine
        }
        // W7/P5 — advance (or clear) the negative-register run. LIVE ONLY, and
        // only once an echo has actually been produced: a turn where the echo
        // stayed silent neither extends nor forgives the run.
        if live {
            negativeSoundEchoRun = (leadValence ?? 0) < 0 ? negativeSoundEchoRun + 1 : 0
        }
        // "lately", not "when it landed" — warmth on her turn is the room's
        // temperature at encode (assistant completions never raise warmth
        // themselves), so the honest claim is what she sounded like in warm
        // moments, not proof the line landed (gpt-5.5 MED, 2026-07-03).
        var line = "- Sound: lately you've sounded like \(fragments.joined(separator: " · "))"
        if !wornFragmentTokens.isEmpty || !wornEdgeTokens.isEmpty {
            line += Self.soundRutAwarenessSuffix
        }
        return line
    }

    private static let soundRutAwarenessSuffix =
        " — a few of the same words keep echoing lately; you've got more range than that"
    private static let soundRutAwarenessLine =
        "- Sound: a few of the same words keep echoing lately; you've got more range than that"

    /// Distinctive tokens at the conversational edges of one assistant turn.
    /// `soundEchoFragment` remains the exemplar source; this separate view is
    /// awareness-only so a closing tic can be noticed without quoting it back.
    private func soundRutEdgeTokens(_ summary: String) -> Set<String> {
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

        let tail = closingSentences.suffix(dynamics.soundRutEdgeSentenceCount)
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

    /// A "reflective takeaway" that's really TASK-STATUS ("one thread still open — X I haven't
    /// closed", "follow up on the overdue Y") is task-tracking wearing a view's clothes; it does
    /// NOT belong in her Inner line. Her subconscious is feelings/views/continuity, not a to-do
    /// status (User, 2026-06-30). Genuine reflections about her felt state still surface. Older
    /// takeaways written while commitments existed can carry this language — filter them out.
    private func isTaskStatusReflection(_ text: String) -> Bool {
        let lower = text.lowercased()
        return containsAny(lower, [
            "haven't closed", "hasn't closed", "yet to close", "not yet closed",
            "thread still open", "still open —", "follow up on", "overdue",
            "still owe", "promised to", "left it open", "unclosed", "still hasn't",
        ])
    }

    /// Drop verbatim-duplicate capsule lines (the lossy inner-state translator can map
    /// several workspace nodes or takeaway seeds onto the same cue), preserving order and
    /// the first occurrence. Keeps the bounded capsule from spending its budget on repeats.
    private func dedupedCapsuleLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.insert(key).inserted { out.append(line) }
        }
        return out
    }

    /// The felt fingerprint capsule line (User, 2026-07-08): her live emotional +
    /// attentional state in a few honest words she FEELS, not sentences she reads.
    /// Replaces the Focus/Feeling/Voice lines. Maps her live signals (mood valence,
    /// substrate affect, organism chemistry) onto the affect-science dimensions; the
    /// organism supplies the richest dims (clarity/agency/confidence/fatigue), with a
    /// substrate + neutral fallback when the organism is off.
    private func feltFingerprintLine(
        signals: FeltSignals,
        affectEnabled: Bool? = nil
    ) -> String? {
        guard affectEnabled ?? configuration.affectEnabled else { return nil }
        return CognitiveSubstrate.feltFingerprint(
            signals, intensityFloor: dynamics.feltIntensityFloor)
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
        proxies capturedProxies: CognitiveFeltProxyReads? = nil
    ) -> FeltSignals {
        let now = explicitNow ?? dependencies.now()
        let dyn = dynamics
        let mood = explicitMood ?? derivedMood(at: now)
        let currentAffect = explicitAffect ?? projectedAffect(at: now)
        // Immediate workspace tint (User, 2026-07-08): what she's HOLDING right now colors
        // her felt valence. RECENCY-WEIGHTED with a SHORT half-life (the fast layer) so the
        // CURRENT emotional moment leads — a fresh sting reads through even amid a good
        // session, then fades over a few turns as its weight decays. A flat mean drowned
        // the sting under the session's positive history; mood (the 0.4 term) is the slow
        // 6h-half-life background, this is the fast foreground.
        let feltNodes = workspaceItems.prefix(6).map(\.node)
            .filter { feltDirection(valence: $0.emotionalValence, arousal: $0.emotionalArousal, warmth: $0.emotionalWarmth) != nil }
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
            var wsum = 0.0, wtot = 0.0, peakW = -1.0, peak = 0.0
            for n in feltNodes {
                let age = max(0, now.timeIntervalSince(n.lastActivatedAt))
                // (M15, 2026-07-09: the toolObservation half-weight that used to sit
                // here was UNREACHABLE — capsuleEligibleWorkspaceNode already excludes
                // tool nodes from this array. The live grief bug was actually fixed by
                // the moodWeight floor below; tool noise reaches the fingerprint only
                // through derivedMood, which the floor bounds.)
                let w = pow(0.5, age / dyn.fingerprintTintHalfLife)
                wsum += w * n.emotionalValence; wtot += w
                if w > peakW { peakW = w; peak = n.emotionalValence }
            }
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
        return FeltSignals(
            valence: effectiveValence,
            arousal: currentAffect.arousal,
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
            confidence: chem?.confidence
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

    private func innerThoughtSeedLine(for seed: CognitiveThoughtSeed) -> String {
        let prefix = seed.kind == .reflectionTakeaway ? "Inner" : "Thread"
        return "- \(prefix): \(thoughtSeedCapsuleText(seed))"
    }

    private func thoughtSeedCapsuleText(_ seed: CognitiveThoughtSeed) -> String {
        var text = capsuleSignalText(seed.text, maxCharacters: 180)
        if seed.kind == .reflectionTakeaway {
            text = strippingPrefix("Reflection takeaway:", from: text)
            text = strippingPrefix("Reading the state honestly:", from: text)
            text = strippingPrefix("Reading the capsule honestly:", from: text)
            text = text.replacingOccurrences(
                of: "the capsule is warm, populated, low-tension",
                with: "warm, connected, low-tension",
                options: [.caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: "capsule",
                with: "inner state",
                options: [.caseInsensitive]
            )
        }
        return capsuleSignalText(text, maxCharacters: 180)
    }

    private func innerStateProvenance(
        from workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        thoughtSeeds explicitThoughtSeeds: [CognitiveThoughtSeed]? = nil
    ) -> [UUID] {
        var ids = workspaceItems.map(\.id)
        for seed in explicitThoughtSeeds ?? projectedThoughtSeeds(at: now) {
            ids.append(contentsOf: seed.sourceNodeIds)
        }
        return unique(ids)
    }

    public func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        let requestTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            request.surface,
            request.sessionId ?? "",
            request.userMessage,
        ])
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let capsule = await compileCapsule(request)
        guard capsule.mode == .inject,
              !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capsule
    }

    /// Compile the production capsule from one fixed-time copied read in a
    /// single substrate admission. The live field, persistence, decay anchors,
    /// and surfaced-state bookkeeping remain untouched.
    public func prepareFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        at fixedAt: Date
    ) async -> CognitiveCapsule? {
        let requestTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            request.surface,
            request.sessionId ?? "",
            request.userMessage,
        ])
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let read = await frozenRead(at: fixedAt, currentSessionId: request.sessionId)
        let capsule = compileFrozenCapsule(request, from: read)
        guard capsule.mode == .inject,
              !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capsule
    }

    private func fitCapsuleLines(_ lines: [String], maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard maxCharacters > 0 else {
            return ("", !lines.isEmpty)
        }
        var kept: [String] = []
        var used = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let separatorCost = kept.isEmpty ? 0 : 1
            if used + separatorCost + line.count <= maxCharacters {
                kept.append(line)
                used += separatorCost + line.count
                continue
            }

            let available = maxCharacters - used - separatorCost
            // The Sound echo is all-or-nothing: a clipped quote would put words
            // in her mouth mid-sentence (gpt-5.5 MED, 2026-07-03). Other lines
            // keep the sentence-aware clip.
            if available >= 24, !line.hasPrefix("- Sound:") {
                let clipped = capsuleLineText(line, maxCharacters: available)
                if !clipped.isEmpty {
                    kept.append(clipped)
                }
            }
            return (kept.joined(separator: "\n"), true)
        }
        return (kept.joined(separator: "\n"), false)
    }

    func capsuleLineText(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters >= 0, normalized.count > maxCharacters else { return normalized }

        if let sentence = firstCompleteSentence(in: normalized, maxCharacters: maxCharacters),
           sentence.count >= min(48, maxCharacters) {
            return sentence
        }

        let suffix = "..."
        let prefixLimit = max(0, maxCharacters - suffix.count)
        guard prefixLimit > 0 else {
            return bounded(normalized, maxCharacters: maxCharacters)
        }
        let prefix = String(normalized.prefix(prefixLimit))
        if let breakIndex = prefix.lastIndex(where: { $0 == " " || $0 == "," || $0 == ";" || $0 == ":" }) {
            let candidate = String(prefix[..<breakIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= min(48, prefixLimit) {
                return candidate + suffix
            }
        }
        return prefix + suffix
    }

    private func firstCompleteSentence(in text: String, maxCharacters: Int) -> String? {
        guard maxCharacters > 0, !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(maxCharacters, text.count))
        var index = text.startIndex
        var end: String.Index?
        while index < limit {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                end = text.index(after: index)
            }
            index = text.index(after: index)
        }
        guard let end else { return nil }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }
}

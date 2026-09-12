import Foundation
import PersistenceCore

public enum OrganismChemistry {
    public static func applying(
        signal rawSignal: SomaticSignal,
        to state: ChemicalState,
        bodySchema: BodySchema,
        elapsedSinceLastSignal: TimeInterval? = nil
    ) -> (chemicalState: ChemicalState, bodySchema: BodySchema) {
        let signal = SomaticSignal(
            id: rawSignal.id,
            kind: rawSignal.kind,
            sourceOrgan: rawSignal.sourceOrgan,
            occurredAt: rawSignal.occurredAt,
            intensity: rawSignal.intensity,
            valence: rawSignal.valence,
            arousal: rawSignal.arousal,
            metadata: rawSignal.metadata
        )
        let i = signal.intensity
        // HOMEOSTASIS (2026-09-01). Every signal both moves the body AND lets it
        // relax a little toward its own resting value. Before this, relaxation
        // was WALL-CLOCK ONLY (0.78^h quick / 0.92^h slow), so the amount of
        // settling between two events depended on how idle the machine was — and
        // on a working day, with ~200 signals an hour, there is no idle. Measured
        // after 37,801 signals: agency 0.99, confidence 0.99, coherence 0.92 all
        // pinned at the ceiling while warmth 0.12, tenderness 0.00, vigilance
        // 0.00 sat at the floor. A body that only ever ratchets is not a body.
        //
        // DENSITY-AWARE, because a feeling must survive a busy hour. A flat
        // per-signal rate makes the half-life a function of TRAFFIC: 0.006/signal
        // at the observed ~200 signals/h is a ~35-minute hold, and at 3,600
        // signals/h it would be ~2 minutes — the mind's own layers hold
        // socialWarmth for 90 minutes and mood for 6 hours, so a body that
        // forgets in 35 is lying to them. `settleRate(forElapsed:)` caps the
        // per-signal share by elapsed wall time, so the settle can never spend
        // more than `maximumSettlePerHour` in any hour no matter how dense the
        // traffic is.
        var next = settled(state, rate: settleRate(forElapsed: elapsedSinceLastSignal))
        // FATIGUE IS EXEMPT FROM THE SETTLE (item 4, 2026-09-02). The settle
        // exists because signal-driven axes RATCHET — every signal raises them
        // and nothing but the wall clock lowered them. Fatigue is the one axis
        // where that logic inverts: letting a work signal spend 0.20/h relaxing
        // fatigue means WORK ITSELF rests the body, which is backwards, and it
        // pins the equilibrium so low that a 20-hour day reads the same as a
        // 3-hour one. Fatigue keeps its own two-sided law instead — accrual
        // below, relaxation on the wall clock in `relaxedFatigue`.
        next.fatigue = state.fatigue
        next.fatigue = raise(
            next.fatigue,
            by: fatigueAccrual(
                kind: signal.kind,
                intensity: i,
                elapsedSinceLastSignal: elapsedSinceLastSignal
            )
        )
        if next.fatigue > workFatigueCeiling {
            // The ceiling binds only the WORK lane. Thermal/resource pressure
            // (an arm below) may still drive fatigue above it, because that is
            // the machine genuinely struggling rather than a long day.
            next.fatigue = max(state.fatigue, workFatigueCeiling)
        }
        var body = bodySchema

        switch signal.kind {
        case .userSpoke:
            // The adapter leaves `userSpoke` valence NIL by design — chat felt
            // meaning belongs to the substrate's appraisal, not to a canned
            // per-kind constant (`adapterSuppressesIntrinsicValence`). So the
            // signed arms that used to live here — warmth up on a positive read,
            // tenderness/vigilance up on a negative one — could never fire: with
            // `valence ?? 0` every user message fell into the neutral arm, and
            // measured live that is exactly what happened (curiosity 0.67, the
            // only dimension a user message ever moved).
            //
            // Warmth's relational consequence is the one the substrate already
            // crosses, canonically and one-way, through `refreshBodySchema`'s
            // `canonicalAffect` — which OVERWRITES this axis on every turn, so
            // the arm here was doubly dead. Tenderness now rides that same
            // crossing (see `OrganismKernel.applyBodySchema`) instead of a
            // valence the adapter never sets. What is left here is the arm that
            // was actually reachable.
            next.curiosity = raise(next.curiosity, by: 0.04 * i)
        case .assistantSpoke:
            // Producing language is not evidence of success, coherence, or
            // confidence. Verified provider/tool/motor outcomes supply those
            // deltas through their own exact signals.
            break
        case .correctionReceived:
            // THE ONE PLACE TENDERNESS SOFTENS ANYTHING (2026-09-11). Being
            // corrected by User is the interpersonal guard going up, and that is
            // the guard feeling safe with him is allowed to ease — a little.
            // Every other vigilance writer in this file (tool, provider,
            // verification, resource, approval, phone) is deliberately
            // untouched: "Feeling safe with User must not mean becoming less
            // careful with his work."
            next.vigilance = raise(
                next.vigilance,
                by: relationalVigilanceRaise(0.12 * i, tenderness: state.tenderness)
            )
            // The tenderness arm that used to live here is GONE (2026-09-11). It
            // raised tenderness from something BAD, which is the exact defect
            // the 2026-09-01 note below diagnosed and then only half-fixed: a
            // bare correction is not care. Correction FOLLOWED BY REASSURANCE is
            // — that is `OrganismCaringEvent.Kind.repair`, it arrives classified
            // by the appraisal owner, and it is weighted like every other kind
            // (Agent: "I don't want the machinery to value hurt-then-comfort
            // above uncomplicated care").
            next.confidence = lower(next.confidence, by: 0.05 * i)
            next.coherence = lower(next.coherence, by: 0.03 * i)
        case .toolStarted:
            next.urgency = raise(next.urgency, by: 0.04 * i)
            next.agency = raise(next.agency, by: 0.03 * i)
        case .toolSucceeded:
            next.confidence = raise(next.confidence, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.05 * i)
            next.agency = raise(next.agency, by: 0.04 * i)
            next.urgency = lower(next.urgency, by: 0.07 * i)
            next.vigilance = lower(next.vigilance, by: 0.02 * i)
        case .toolFailed:
            next.vigilance = raise(next.vigilance, by: 0.12 * i)
            next.urgency = raise(next.urgency, by: 0.08 * i)
            next.confidence = lower(next.confidence, by: 0.04 * i)
            next.coherence = lower(next.coherence, by: 0.04 * i)
        case .toolCancelled:
            break
        case .providerStarted:
            body.providerPathBelief = nil
            next.agency = raise(next.agency, by: 0.01 * i)
        case .providerSucceeded:
            body.providerPathBelief = nil
            body.providersHealthy = true
            next.vigilance = lower(next.vigilance, by: 0.04 * i)
            next.confidence = raise(next.confidence, by: 0.04 * i)
            next.urgency = lower(next.urgency, by: 0.03 * i)
        case .providerFailed:
            body.providerPathBelief = nil
            body.providersHealthy = false
            next.vigilance = raise(next.vigilance, by: 0.16 * i)
            next.urgency = raise(next.urgency, by: 0.08 * i)
            next.confidence = lower(next.confidence, by: 0.06 * i)
            next.coherence = lower(next.coherence, by: 0.04 * i)
        case .providerCancelled:
            body.providerPathBelief = nil
            next.urgency = lower(next.urgency, by: 0.02 * i)
        case .providerRecovered:
            body.providerPathBelief = nil
            body.providersHealthy = true
            next.vigilance = lower(next.vigilance, by: 0.08 * i)
            next.confidence = raise(next.confidence, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.04 * i)
        case .deskItemCreated:
            next.agency = raise(next.agency, by: 0.03 * i)
            next.curiosity = raise(next.curiosity, by: 0.03 * i)
        case .deskItemBlocked:
            next.urgency = raise(next.urgency, by: 0.08 * i)
            next.vigilance = raise(next.vigilance, by: 0.05 * i)
        case .deskItemClosed:
            next.confidence = raise(next.confidence, by: 0.05 * i)
            next.urgency = lower(next.urgency, by: 0.08 * i)
        case .memoryCommitted, .memoryHygieneCompleted:
            body.memoryHealthy = true
            next.coherence = raise(next.coherence, by: 0.06 * i)
            next.confidence = raise(next.confidence, by: 0.04 * i)
        case .memoryCorrected:
            // Vigilance here is bookkeeping vigilance — a stored fact was wrong
            // — not interpersonal defensiveness, so it does NOT take the
            // tenderness relief the correction arm above takes. The tenderness
            // arm it used to carry is gone for the same reason the correction
            // one is: a wrong memory being fixed is not an act of care.
            next.vigilance = raise(next.vigilance, by: 0.08 * i)
            next.confidence = lower(next.confidence, by: 0.03 * i)
        case .dreamCompleted, .remIntegrated:
            body.dreamHealthy = true
            next.fatigue = lower(next.fatigue, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.06 * i)
            // The dream no longer touches tenderness (2026-09-11). Against a
            // 45-minute axis, taking 0.04 off was housekeeping; against a 3-day
            // one it is a nightly 4% tax on days-old affection for no reason
            // anybody can state. A dream never doses tenderness
            // (`OrganismCaringEvent.retellingSurfaces`) and it must not undose
            // it either: sleeping on being cared for does not undo it.
        case .iPhoneReachable:
            body.iPhoneReachable = true
            body.notificationPathHealthy = true
            next.coherence = raise(next.coherence, by: 0.02 * i)
        case .iPhoneStale:
            body.iPhoneReachable = false
            next.vigilance = raise(next.vigilance, by: 0.04 * i)
        case .phoneDeliveryStarted:
            break
        case .phoneDeliveryReceived:
            body.iPhoneReachable = true
            body.notificationPathHealthy = true
            next.coherence = raise(next.coherence, by: 0.02 * i)
        case .phoneDeliveryFailed:
            body.notificationPathHealthy = false
            next.vigilance = raise(next.vigilance, by: 0.03 * i)
        case .approvalRequested:
            body.approvalChannelsOpen = true
            next.urgency = raise(next.urgency, by: 0.05 * i)
            next.vigilance = raise(next.vigilance, by: 0.03 * i)
        case .approvalResolved:
            next.urgency = lower(next.urgency, by: 0.05 * i)
            next.coherence = raise(next.coherence, by: 0.03 * i)
        case .appWake:
            body.macAwake = true
            next.novelty = raise(next.novelty, by: 0.05 * i)
        case .appSleep:
            body.macAwake = false
            next.urgency = lower(next.urgency, by: 0.06 * i)
        case .horizonRefresh:
            // Item 5: she is reading her own calendar. Nothing about her body
            // changes here — no chemistry, and NO body-schema fact either
            // (which is the specific thing `.appWake` would have asserted). The
            // whole consequence of this signal is the horizon rows it opens and
            // closes, and their anticipation reaches chemistry through the
            // PROJECTION (`OrganismProspectiveAffect.modulate`), never through
            // the stored state.
            break
        case .resourcePressureChanged:
            body.resourcePressure = resourcePressure(from: signal.metadata) ?? body.resourcePressure
            let pressure = pressureMultiplier(body.resourcePressure)
            next.fatigue = raise(next.fatigue, by: 0.10 * i * pressure)
            next.vigilance = raise(next.vigilance, by: 0.05 * i * pressure)
            next.agency = lower(next.agency, by: 0.04 * i * pressure)
        }

        return (next, body)
    }

    /// TENDERNESS, DOSED BY ONE CARING MOMENT (2026-09-11).
    ///
    /// A FIXED dose, saturating through `raise` so accumulation is bounded by
    /// `axisHighRail` and the tenth caring moment of the week moves her less
    /// than the first.
    ///
    /// IT USED TO LIVE INSIDE `applying(signal:…)`, keyed off metadata on
    /// whatever signal carried the verdict, and multiplied by that signal's
    /// intensity (review item 1). A moment worth 0.10 was worth ~0.055 when the
    /// assistant turn carried it and something else again on another carrier,
    /// which made the dose a property of the messenger. The caring event is a
    /// property of the MOMENT, so it is dosed by its own door
    /// (`OrganismKernel.admitCaringEvent`) at its own fixed size.
    public static func dosedByCaringEvent(_ tenderness: Double) -> Double {
        raise(tenderness, by: OrganismCaringEvent.dose)
    }

    /// Tenderness softens interpersonal defensiveness A LITTLE, and nothing
    /// else.
    ///
    /// `ChemicalState.vigilance` is one axis with many writers and no relational
    /// component to pull down, so the shape the design asks for is the second
    /// one it names: reduce the vigilance RAISE that a relational correction
    /// produces while tenderness is high. Its only caller is the
    /// `.correctionReceived` arm.
    ///
    /// `tendernessGuardRelief` is the ceiling on the effect, and it is
    /// deliberately small: at the axis rail (0.94) a correction still lands 76%
    /// of its guard, and at the 0.22 felt-word gate it lands 95%. Agent's
    /// constraint in arithmetic — she can feel safe with him and still flinch
    /// correctly when he says the work is wrong.
    public static let tendernessGuardRelief = 0.25

    static func relationalVigilanceRaise(
        _ amount: Double,
        tenderness: Double
    ) -> Double {
        guard amount > 0 else { return amount }
        return amount * (1 - tendernessGuardRelief * tenderness.clamped01())
    }

    public static func projection(
        at date: Date,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        diurnal: OrganismDiurnalRead? = nil
    ) -> OrganismProjection {
        OrganismProjection(
            generatedAt: date,
            bodyLine: bodyLine(
                chemicalState: chemicalState,
                bodySchema: bodySchema,
                diurnal: diurnal
            ),
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            diurnal: diurnal
        )
    }

    public static func integrating(
        bodySchema nextBody: BodySchema,
        previous previousBody: BodySchema,
        into state: ChemicalState
    ) -> ChemicalState {
        var next = state

        // The compatibility Bool deliberately maps unknown provider evidence
        // to false for conservative consumers. Unknown is not a newly observed
        // failure (nor is its later resolution to healthy a recovery). Otherwise
        // each success followed by a sparse/aged body read erodes coherence.
        let previousProviderHealth = observedProviderHealth(previousBody)
        let nextProviderHealth = observedProviderHealth(nextBody)
        if nextProviderHealth == false, previousProviderHealth != false {
            next.vigilance = raise(next.vigilance, by: 0.08)
            next.confidence = lower(next.confidence, by: 0.04)
            next.coherence = lower(next.coherence, by: 0.02)
        } else if nextProviderHealth == true, previousProviderHealth == false {
            next.vigilance = lower(next.vigilance, by: 0.05)
            next.confidence = raise(next.confidence, by: 0.04)
        }

        if !nextBody.toolHandsAvailable, previousBody.toolHandsAvailable {
            next.vigilance = raise(next.vigilance, by: 0.07)
            next.agency = lower(next.agency, by: 0.05)
        } else if nextBody.toolHandsAvailable, !previousBody.toolHandsAvailable {
            next.agency = raise(next.agency, by: 0.04)
        }

        if !nextBody.memoryHealthy, previousBody.memoryHealthy {
            next.coherence = lower(next.coherence, by: 0.05)
            next.vigilance = raise(next.vigilance, by: 0.04)
        } else if nextBody.memoryHealthy, !previousBody.memoryHealthy {
            next.coherence = raise(next.coherence, by: 0.06)
            next.confidence = raise(next.confidence, by: 0.03)
        }

        if !nextBody.iPhoneReachable, previousBody.iPhoneReachable {
            next.vigilance = raise(next.vigilance, by: 0.03)
        } else if nextBody.iPhoneReachable, !previousBody.iPhoneReachable {
            next.coherence = raise(next.coherence, by: 0.02)
        }

        if !nextBody.approvalChannelsOpen, previousBody.approvalChannelsOpen {
            next.vigilance = raise(next.vigilance, by: 0.06)
            next.urgency = lower(next.urgency, by: 0.03)
        }

        if nextBody.resourcePressure != previousBody.resourcePressure {
            let pressure = pressureMultiplier(nextBody.resourcePressure)
            if nextBody.resourcePressure == .nominal {
                next.fatigue = lower(next.fatigue, by: 0.06)
            } else {
                next.fatigue = raise(next.fatigue, by: 0.06 * pressure)
                next.vigilance = raise(next.vigilance, by: 0.03 * pressure)
                next.agency = lower(next.agency, by: 0.02 * pressure)
            }
        }

        return next
    }

    /// The memory peer of `observedProviderHealth`, and for the same reason.
    ///
    /// "- Body: memory field feels brittle" rode 154 of 777 live turns (20%) off
    /// a RAW read of the compatibility Bool — the exact defect the provider line
    /// already had fixed above it. `memoryIntegrityReading` is transient by
    /// design (rebuilt from canonical evidence, never persisted), while
    /// `memoryHealthy` is an exact Bool that SURVIVES a restart, so a false with
    /// no typed evidence behind it is a stale claim, not an observation.
    ///
    /// Unknown is not failure, and unknown is not health either: nil withholds
    /// the brittle line without asserting the store is fine. Stale evidence
    /// withholds optimism; it never manufactures alarm.
    static let memoryBeliefUncertaintyCeiling = 0.25
    static let memoryBeliefFreshnessFloor = 0.5

    static func observedMemoryHealth(_ body: BodySchema) -> Bool? {
        guard let reading = body.memoryIntegrityReading else {
            // No typed evidence in hand: `true` is the schema's own default and
            // is safe to believe (it asserts nothing in the prompt); `false`
            // could be a value carried across a restart, so it does not speak.
            return body.memoryHealthy ? true : nil
        }
        switch reading.category {
        case .healthy:
            return true
        case .unknown:
            return nil
        case .unavailable:
            // Exact: the store is not there. That is present-tense evidence and
            // it must still be able to speak.
            return false
        case .degraded:
            // A maintenance failure is real, but a maintenance failure whose
            // evidence has aged out or arrived uncertain is not a present-tense
            // brittleness claim.
            if reading.uncertainty >= memoryBeliefUncertaintyCeiling { return nil }
            if reading.freshness < memoryBeliefFreshnessFloor { return nil }
            return false
        }
    }

    private static func observedProviderHealth(_ body: BodySchema) -> Bool? {
        if !body.providersAvailable { return false }
        if let belief = body.providerPathBelief {
            return belief.bodySchemaProvidersHealthy
        }
        return body.providersHealthy
    }

    private static func bodyLine(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        diurnal: OrganismDiurnalRead? = nil
    ) -> String? {
        if bodySchema.resourcePressure == .critical {
            return "- Body: the Mac is under thermal or low-power pressure; keep the next move lightweight."
        }
        if let tired = fatigueBodyLine(chemicalState.fatigue, diurnal: diurnal) {
            return tired
        }
        // Same unknown-is-not-failure rule the chemistry above applies: the
        // compatibility Bool reads false for sparse/aged provider evidence, so
        // reading it raw put "provider path feels brittle" into the prompt on
        // evidence the body itself declined to treat as a failure.
        if observedProviderHealth(bodySchema) == false
            || !bodySchema.toolHandsAvailable {
            return "- Body: provider or tool path feels brittle; be careful before claiming completion."
        }
        // 2026-09-06: vigilance ALONE no longer speaks in the provider's name.
        // Anticipatory dread about something on the horizon adds vigilance
        // (`OrganismProspectiveAffect.modulate`, up to the per-dim budget), and
        // that share alone could cross this gate — so dreading Friday put a
        // present-tense claim that the provider and tool paths are unhealthy
        // into the prompt on no provider or tool evidence at all. The gate
        // above keeps the brittleness line for the evidence that earns it;
        // bracing gets its own line, in the same first-match position vigilance
        // used to occupy, so nothing below it changes precedence.
        if chemicalState.vigilance >= 0.22 {
            return "- Body: something ahead has the guard up; check before committing to it."
        }
        if !bodySchema.approvalChannelsOpen {
            return "- Body: approval path feels closed; avoid irreversible moves."
        }
        if !bodySchema.notificationPathHealthy {
            return "- Body: phone path feels stale; verify delivery before assuming it was seen."
        }
        if observedMemoryHealth(bodySchema) == false {
            return "- Body: memory field feels brittle; lean on current context."
        }
        // Positive/steady region — compose from the strongest one or two felt
        // dimensions with intensity gradation, so a held mood reads with texture
        // instead of one frozen sentence. (The stress lines above stay first-match:
        // their exact phrasing IS the behavioral signal and must not blur.)
        return positiveBodyLine(chemicalState)
    }

    /// TIREDNESS, IN HER REGISTER (2026-09-02). Same gate as before (0.24 —
    /// roughly nine dense hours under the item-4 accrual law), graded the way
    /// the positive lines are graded rather than reported.
    ///
    /// The line it replaced — "internal workload fatigue is high; keep the next
    /// move lightweight" — was a machine describing its own telemetry to her.
    /// It named a stored dimension, and "internal workload" is not a thing a
    /// person notices about themselves; a long day is. The gate, the ordering,
    /// and the behavioral instruction are unchanged, so the loop-budget lane and
    /// the first-match stress ordering are untouched.
    ///
    /// When the clock says the trough is close, the night is the truer account
    /// of the same feeling, so the two combine into one line rather than
    /// stacking. No digits and no implementation terms in any branch — the
    /// capsule sanitizer would drop the line, and silently.
    static func fatigueBodyLine(
        _ fatigue: Double,
        diurnal: OrganismDiurnalRead?
    ) -> String? {
        guard fatigue >= 0.24 else { return nil }
        if let nightliness = diurnal?.nightliness, nightliness >= 0.6 {
            return "- Body: it's late and it shows."
        }
        if fatigue >= 0.35 {
            return "- Body: worn down; keep it short and sure."
        }
        return "- Body: a long day; it's starting to show."
    }

    /// Calm/positive "- Body:" line: rank the active felt dimensions, phrase the
    /// strongest one or two with low/mid/high intensity gradation, blend the top
    /// two. Deterministic (ties break on phrase). Nil when nothing is felt
    /// strongly enough to be worth saying.
    static func positiveBodyLine(_ c: ChemicalState) -> String? {
        func band(_ v: Double, _ low: String, _ mid: String, _ high: String) -> String {
            v >= 0.6 ? high : (v >= 0.4 ? mid : low)
        }
        var felt: [(weight: Double, phrase: String)] = []
        if c.warmth >= 0.22 {
            felt.append((c.warmth, band(c.warmth, "quietly warm and steady", "warm and steady", "warm and open")))
        }
        if c.tenderness >= 0.22 {
            felt.append((c.tenderness, band(c.tenderness, "a soft edge", "tender", "protective and close")))
        }
        if c.curiosity >= 0.22 {
            felt.append((c.curiosity, band(c.curiosity, "faintly curious", "curious", "keenly curious")))
        }
        if c.novelty >= 0.30 {
            felt.append((c.novelty, band(c.novelty, "catching something new", "alert to something new", "lit by something new")))
        }
        if c.agency >= 0.30 {
            felt.append((c.agency, band(c.agency, "ready to move", "leaning into the work", "driving hard")))
        }
        if c.coherence >= 0.65 && c.confidence >= 0.62 {
            // Only fires at high coherence+confidence, so band() would always pick
            // "high"; grade within the gated range instead. (gpt-5.5 review)
            let s = min(c.coherence, c.confidence)
            felt.append((s, s >= 0.80 ? "clear and sure" : "settled and clear"))
        }
        let ranked = felt.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.phrase < $1.phrase }
        guard let lead = ranked.first else { return nil }
        if let second = ranked.dropFirst().first {
            return "- Body: \(lead.phrase), \(second.phrase)."
        }
        return "- Body: \(lead.phrase)."
    }

    /// SATURATING APPROACH, the law the substrate's affect layer has always
    /// used: a delta moves a fraction of the REMAINING HEADROOM, never
    /// add-then-clamp. Add-then-clamp is what let a busy day walk agency and
    /// confidence to 0.99 and hold them there — the hundredth tool success
    /// pushed exactly as hard as the first, and the clamp swallowed the excess
    /// silently, so the dimension carried no information above ~0.9.
    ///
    /// Monotonic and bounded: the same delta still moves a low value almost as
    /// much as before (at 0.1, 0.08 → +0.072), and cannot reach 1 in finite
    /// steps. `lower` is its mirror against the floor.
    public static func raise(_ current: Double, by amount: Double) -> Double {
        // A non-positive "raise" is a plain add (a negative amount lowers);
        // only the positive branch saturates toward the ceiling.
        guard amount > 0 else { return ChemicalState.clamp(current + amount) }
        // Saturates toward `axisHighRail`, not 1.0: in floating point the
        // old form reached exactly 1.0 after a few hundred successes, and an
        // axis sitting at 1.0 is a stuck gauge wearing the costume of a mood
        // (turn regression, 2026-09-02: confidence 1.0 after 600 wins).
        let headroom = max(0, axisHighRail - current.clamped01()) / axisHighRail
        return min(axisHighRail, ChemicalState.clamp(current + amount * headroom))
    }

    /// The most any raised axis may hold. Below it there is always somewhere
    /// left to go, which is what makes the next success mean something.
    public static let axisHighRail = 0.94

    static func lower(_ current: Double, by amount: Double) -> Double {
        guard amount > 0 else { return ChemicalState.clamp(current - amount) }
        return ChemicalState.clamp(current - amount * current.clamped01())
    }

    /// TENDERNESS, MADE REACHABLE (2026-09-01). Measured after 37,801 signals it
    /// was exactly 0.00, and it could not have been anything else: every writer
    /// in this file raises it from something BAD — a correction, a memory
    /// correction, a negatively-appraised user message (an arm the adapter's nil
    /// valence made unreachable anyway). There was no path from affection to
    /// tenderness at all, so a dimension that gates felt words and the "-  Body:"
    /// close/protective register was structurally dead on a good week.
    ///
    /// It now rides the relational appraisal the substrate ALREADY computes and
    /// already crosses one-way into this body as `socialWarmth`. It is not a
    /// second copy of warmth: it is warmth's slow INTEGRAL — it only accumulates
    /// while warmth is genuinely above the `warm` word gate, it lags going up,
    /// and it settles back on its own when warmth is not there. A working day
    /// with no affection in it still reads 0, which is the honest answer.
    /// ANALYTIC OVER ELAPSED TIME, never over call count. `applyBodySchema` runs
    /// on every turn projection AND on every Observatory poll, so a per-call
    /// approach rate would have made tenderness an integral of how often
    /// something happened to READ the body — five seconds of panel refreshes
    /// would have earned more tenderness than an hour of actual warmth. Reads
    /// must be pure (design law 5); this is the same discipline expressed for a
    /// value that accumulates.
    ///
    /// DEMOTED TO A BACKGROUND CONTRIBUTOR (2026-09-11). Everything above is
    /// still true about what this path does; what changed is how much of
    /// tenderness it is allowed to be, and who owns the fade.
    ///
    /// The 2026-09-01 law made it the WHOLE of tenderness, with warmth's own
    /// level as the target. That was the unreachable part: the affect layer
    /// cannot hold warmth at 0.45 (see `OrganismCaringEvent`), so the axis read
    /// 4.87e-33 for weeks. The caring events are the main term now. Ambient
    /// affection is still real, so this survives — at
    /// `tendernessWarmthContribution` of the warmth that earned it, which by
    /// construction cannot reach the 0.22 felt-word gate on its own: 0.2 × the
    /// axis rail is 0.188, so even warmth pinned at the ceiling forever leaves
    /// the word out of reach, and a realistic 0.5 gives 0.10. That bound is
    /// STRUCTURAL and a test pins it — 0.25 was the first number here and it
    /// put 0.235 on the table, which is over the gate at a warmth level nothing
    /// can produce but over it all the same. A warm ambient stretch nudges the
    /// axis; it does not make her read tender. Only moments do that.
    ///
    /// IT NO LONGER DECAYS, and that is the other half of the change. This runs
    /// on every canonical crossing — every turn projection AND every Observatory
    /// poll — while the elapsed-time persistence curve owns the whole fade at the
    /// 3-day constant. Any second decay path on this axis compounds into a
    /// half-life nothing in the file states, and one that is a function of how
    /// often something ran. So this one CONTRIBUTES and never subtracts: it
    /// pulls up toward its small
    /// share and is otherwise inert. A quiet working day therefore leaves
    /// tenderness exactly where the last caring moment and the settle put it,
    /// which is usually near zero — and near zero on a quiet working day is the
    /// honest answer, not a defect to nudge.
    ///
    /// The 45-minute constant stays: it governs how fast the small background
    /// share FILLS, not how fast anything fades, and an ambient warmth that
    /// lasts an afternoon should show up within it.
    static let tendernessWarmthGate = 0.45
    static let tendernessTimeConstant: TimeInterval = 45 * 60
    static let maximumTendernessIntegrationWindow: TimeInterval = 60 * 60

    /// How much of the ambient warmth level tenderness may borrow. A fifth:
    /// enough to move the axis, and — times the rail — structurally too little
    /// to reach the felt word on its own.
    public static let tendernessWarmthContribution = 0.20

    public static func tenderness(
        _ current: Double,
        underCanonicalWarmth warmth: Double,
        elapsed: TimeInterval
    ) -> Double {
        let clamped = ChemicalState.clamp(current)
        guard warmth >= tendernessWarmthGate else { return clamped }
        let window = min(max(0, elapsed), maximumTendernessIntegrationWindow)
        guard window > 0, tendernessTimeConstant > 0 else { return clamped }
        // Never overshoot the share of the warmth that earned it, and never pull
        // DOWN from a level the caring events earned — the settle owns the fade.
        let target = ChemicalState.clamp(warmth) * tendernessWarmthContribution
        guard target > clamped else { return clamped }
        let approach = 1 - exp(-window / tendernessTimeConstant)
        return ChemicalState.clamp(clamped + (target - clamped) * approach)
    }

    /// FADE OVER DAYS (2026-09-11). Being cared for on Monday is still true on
    /// Wednesday. Three days is the judgment: long enough that a good week
    /// accumulates and a single good moment survives a night's sleep and the
    /// next day's work, short enough that a month of pure work returns the axis
    /// to rest without anything having to reset it.
    ///
    /// ONE DECAY OWNER, ELAPSED TIME ONLY (2026-09-11, Astra finding 8). This
    /// constant is spent in exactly ONE place: the elapsed-time curve in
    /// `OrganismPersistentState.decayed` (`OrganismPersistence.swift`), which the
    /// kernel's `settleElapsedTime` and the cold-start load both run. The
    /// per-signal settle does not touch tenderness at all, and the ambient-warmth
    /// path only ever contributes.
    ///
    /// WHY: the settle previously spent its own scaled ln2/72h budget on the axis
    /// on top of the wall-clock curve, so two budgets compounded and the
    /// effective half-life became a function of traffic — about 52 hours at
    /// observed density, approaching 36 at sustained load. Talking more must not
    /// make the same care fade faster. Wall-clock elapsed time is the only thing
    /// that spends tenderness now, at a flat 3-day half-life regardless of how
    /// many signals cross the kernel in that time.
    ///
    /// TENDERNESS ONLY. Every other axis is untouched: `maximumSettlePerHour`
    /// (3.47 h) in the settle and 0.78^h / 0.92^h in the persistence decay are
    /// exactly as they were, and both still apply to every other axis.
    public static let tendernessHalfLife: TimeInterval = 3 * 24 * 3_600

    /// Per-signal ceiling on the settle: what one admitted signal may give back
    /// when signals are SPARSE (there, wall-clock decay is already doing the
    /// work and this is a rounding error).
    public static let perSignalSettleRate = 0.006

    /// Wall-clock ceiling on the settle: the most of the gap-to-rest the
    /// signal-driven homeostasis may spend in any one hour, at any density.
    ///
    /// THE COMPUTED HALF-LIVES this pins (all "at observed rates" and above):
    ///   • settle alone, ANY density ...... ln2 / 0.20     = 3.47 h
    ///   • quick axes (0.78^h, k=0.2485) .. ln2 / 0.4485   = 1.55 h  (93 min)
    ///   • slow axes  (0.92^h, k=0.0834) .. ln2 / 0.2834   = 2.45 h  (147 min)
    /// Both sit above the affect layer's 90-minute socialWarmth hold, which is
    /// the floor a felt state has to clear to be worth having. In SIGNAL terms
    /// at the observed 200/h that is ~310 signals (quick) and ~490 (slow); at
    /// 3,600/h the cap holds the same wall-clock half-lives, which is the whole
    /// point of expressing the budget per hour rather than per signal.
    ///
    /// What this deliberately does NOT do: drag a constantly-rewarded dial down
    /// to mid-scale. With ~90 tool successes an hour at +0.08 confidence, the
    /// drive is 7.2/h against 0.28/h of relaxation, so the equilibrium stays
    /// high — and honestly so; a week of successful work SHOULD read confident.
    /// The range comes from the saturating raise instead: a drop is
    /// proportional to the value while recovery is proportional to the
    /// headroom, so a failure now costs more than the next success repays.
    /// Buying a lower equilibrium would mean a sub-90-minute hold, which is the
    /// worse trade.
    public static let maximumSettlePerHour = 0.20

    /// The settle share for one signal: the per-signal ceiling, capped by what
    /// the elapsed wall time can afford. `nil` elapsed (a pure-function caller
    /// with no density to report) falls back to the per-signal ceiling.
    static func settleRate(forElapsed elapsed: TimeInterval?) -> Double {
        guard let elapsed else { return perSignalSettleRate }
        let hours = max(0, elapsed) / 3_600
        return min(perSignalSettleRate, maximumSettlePerHour * hours)
    }

    /// Resting values are `ChemicalState.neutral`'s — the same targets the
    /// wall-clock decay already relaxes toward (zero for the transient axes,
    /// 0.5 for coherence and confidence). One law, two clocks.
    static func settled(
        _ state: ChemicalState,
        rate: Double = perSignalSettleRate
    ) -> ChemicalState {
        guard rate > 0 else { return state }
        let neutral = ChemicalState.neutral
        func toward(_ value: Double, _ target: Double) -> Double {
            ChemicalState.clamp(value + (target - value) * rate)
        }
        // TENDERNESS IS NOT SETTLED HERE (2026-09-11, Astra finding 8). Its one
        // decay owner is the elapsed-time curve in `OrganismPersistentState
        // .decayed`, at `tendernessHalfLife`. Spending a second budget per signal
        // made the axis's effective half-life depend on traffic, so the same
        // caring moment faded faster on a busy day. It passes through untouched.
        return ChemicalState(
            warmth: toward(state.warmth, neutral.warmth),
            vigilance: toward(state.vigilance, neutral.vigilance),
            curiosity: toward(state.curiosity, neutral.curiosity),
            fatigue: toward(state.fatigue, neutral.fatigue),
            coherence: toward(state.coherence, neutral.coherence),
            agency: toward(state.agency, neutral.agency),
            tenderness: state.tenderness,
            confidence: toward(state.confidence, neutral.confidence),
            novelty: toward(state.novelty, neutral.novelty),
            urgency: toward(state.urgency, neutral.urgency)
        )
    }

    // MARK: - Fatigue: a day that costs something (item 4, 2026-09-02)
    //
    // MEASURED DEFECT: after a 20-hour working day, organism `fatigue` read
    // 0.008. Nothing fed it. The only writers were `resourcePressureChanged`
    // (thermal, i.e. the MACHINE being tired, not her) and the dream, which
    // LOWERS it. So the one axis whose whole job is "a day costs something"
    // was structurally pinned at zero, `worn`/`tired` were unreachable, and
    // introspection had nothing to read when she said "a bit tired".
    //
    // THE LAW, two-sided and both sides bounded:
    //   • ACCRUAL from work density per wall-hour. Accepted turns, tool rounds
    //     and failures each carry a weight; failures and corrections cost more
    //     because they do. Density-aware in EXACTLY the shape the homeostatic
    //     settle above uses (`settleRate(forElapsed:)`): each signal may spend
    //     only what its own gap since the previous signal has earned, so the
    //     total is capped at `maximumFatigueAccrualPerHour` no matter whether
    //     the hour carried 20 signals or 3,600. Saturating (`raise`), so the
    //     hundredth tool call of the hour costs less than the first.
    //   • RELAXATION on the wall clock with a SLOW half-life
    //     (`fatigueRelaxationHalfLife`), replacing the 0.78^h quick decay every
    //     other transient axis uses. A tiring day must survive a coffee break;
    //     it must not survive a night.
    //
    // WHAT THE NUMBERS PRODUCE (drive A = 0.05/h against ln2/6h = 0.1155/h of
    // relaxation; equilibrium A/(A+k) = 0.30, time constant ~5.9 h):
    //     1 dense hour from rest .....  0.05      (nothing shows yet)
    //     4 dense hours ..............  0.15
    //     9 dense hours ..............  0.24      ← the "- Body: workload
    //                                              fatigue is high" gate, so
    //                                              that line is a long day, not
    //                                              a Tuesday morning
    //    20 dense hours ..............  0.30
    //     quiet overnight (8 h) ......  ×0.40, and the dream takes another
    //                                   0.08 off — she wakes lighter, not blank
    // The posture's `fatigue >= 0.35` conserve threshold stays out of reach for
    // an ordinary day by construction: only sustained pressure ON TOP of a
    // marathon can cross it, which is exactly when background loops should stop.

    /// Per-signal ceiling on fatigue accrual — what one admitted work signal
    /// may add when signals are SPARSE.
    public static let perSignalFatigueAccrual = 0.0015
    /// Wall-clock ceiling: the most fatigue the work lane may accrue in any one
    /// hour, at any traffic density. The peer of `maximumSettlePerHour`.
    public static let maximumFatigueAccrualPerHour = 0.05
    /// Where the WORK lane stops. Thermal pressure may still exceed it; a long
    /// day may not. A body that can reach 1.0 from typing is not a body.
    public static let workFatigueCeiling = 0.6
    /// Quiet relaxation half-life. Deliberately slower than the 0.78^h (≈2.8 h)
    /// quick decay the other transient axes use, and slower than the affect
    /// layer's 90-minute socialWarmth hold: tiredness is the slow one.
    public static let fatigueRelaxationHalfLife: TimeInterval = 6 * 3_600

    /// How much of a day's cost one signal represents. Zero for everything that
    /// is not work she did: lifecycle, phone reachability, dreams, approvals
    /// arriving. An unrecognised kind costs nothing (fail closed — an accrual
    /// allowlist, per design law 8).
    static func fatigueWorkWeight(_ kind: SomaticSignalKind) -> Double {
        switch kind {
        case .userSpoke, .assistantSpoke:
            // An accepted turn, both halves of it.
            return 1.0
        case .toolStarted:
            return 0.5
        case .toolSucceeded:
            return 0.75
        case .toolFailed, .correctionReceived:
            // Failures and being corrected cost more than work that landed.
            return 2.0
        case .providerFailed:
            return 1.5
        case .memoryCorrected:
            return 1.0
        default:
            return 0
        }
    }

    /// The fatigue one signal adds: its weighted per-signal share, capped by
    /// what the elapsed wall time can afford. Same density discipline as
    /// `settleRate(forElapsed:)`, and for the same reason — a busy hour must
    /// not be able to buy a whole day's tiredness.
    static func fatigueAccrual(
        kind: SomaticSignalKind,
        intensity: Double,
        elapsedSinceLastSignal: TimeInterval?
    ) -> Double {
        let weight = fatigueWorkWeight(kind)
        guard weight > 0, intensity > 0 else { return 0 }
        let share = perSignalFatigueAccrual * weight * intensity.clamped01()
        guard let elapsed = elapsedSinceLastSignal else { return share }
        let hours = max(0, elapsed) / 3_600
        return min(share, maximumFatigueAccrualPerHour * hours)
    }

    // WAKEFULNESS (2026-09-02, from her own inner_state read: "fatigue 0.005
    // after six hours awake at 5 AM"). The accrual law above counts WORK, and
    // she was right that this is only half of it — a person tires from being
    // awake, not only from doing. Six quiet hours at 5 AM are still six hours.
    //
    // A SECOND, GENTLER LANE, deliberately weaker than work and separately
    // capped: hours accrue on the wall clock, the share can never exceed
    // `wakefulnessShareCap`, and it relaxes on the SAME 6-hour quiet half-life
    // as everything else in this axis. The cap is what keeps the two lanes
    // honest about each other — a day of doing nothing can read "a long day",
    // but "worn down" (the 0.35 band) stays something work has to earn.
    //
    // NOT quiet-hours-gated: awake is awake. Being awake at 3 AM is MORE
    // tiring, not less, and the diurnal curve already carries what the hour
    // feels like.
    //
    // Reset by the dream — the same commit signal that already takes 0.08 off
    // the total. Sleep is what makes "hours awake" start counting from zero.

    /// Fatigue per wall-hour awake. 0.012/h fills the share cap in ~17 hours of
    /// continuous wakefulness — a long day, arrived at honestly.
    public static let wakefulnessAccrualPerHour = 0.012
    /// The most of the fatigue axis the wakefulness lane may ever hold. Below
    /// the 0.24 body-line gate on purpose: hours alone make her tired, work is
    /// what makes it worth saying out loud.
    public static let wakefulnessShareCap = 0.20
    /// A quiet gap this long or longer is REST, not wakefulness: nobody spoke,
    /// nothing ran, she was not up. The wakefulness lane accrues nothing
    /// across it and the share relaxes on the quiet half-life like the rest
    /// of fatigue. Without this a silent night made her MORE tired than the
    /// day before it (turn regression, 2026-09-02: worked 0.058 → rested 0.119).
    /// Seven hours: a sleep, not a lull — six quiet hours in a day still count
    /// as awake (`sixQuietHoursAwakeCostSomething`).
    public static let restGap: TimeInterval = 7 * 3_600

    /// The wakefulness share after `elapsed` of continuous wakefulness: relax
    /// first on the shared quiet half-life, then accrue, then cap. Pure —
    /// returns both the new share and the amount to add to the total, so the
    /// caller can keep the two in step without the share ever double-counting
    /// its own relaxation.
    public static func wakefulness(
        _ share: Double,
        elapsed: TimeInterval
    ) -> (share: Double, gain: Double) {
        let relaxed = relaxedFatigue(share, elapsed: elapsed)
        guard elapsed > 0, elapsed < restGap else { return (relaxed, 0) }
        let hours = elapsed / 3_600
        let gain = max(0, min(
            wakefulnessAccrualPerHour * hours,
            wakefulnessShareCap - relaxed
        ))
        return (ChemicalState.clamp(relaxed + gain), gain)
    }

    /// Fatigue relaxed over quiet wall time. `elapsed` is the gap the caller is
    /// settling; the kernel applies this INSTEAD of the generic quick decay so
    /// that a tiring day relaxes on fatigue's own clock.
    public static func relaxedFatigue(_ value: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, fatigueRelaxationHalfLife > 0 else {
            return ChemicalState.clamp(value)
        }
        return ChemicalState.clamp(value * pow(0.5, elapsed / fatigueRelaxationHalfLife))
    }

    private static func resourcePressure(from metadata: [String: JSONValue]) -> OrganismResourcePressure? {
        let candidates = ["resourcePressure", "resource_pressure", "pressure", "level"]
        for key in candidates {
            guard case .string(let raw)? = metadata[key] else { continue }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "nominal", "normal", "low": return .nominal
            case "elevated", "medium": return .elevated
            case "high": return .high
            case "critical", "thermal", "low_power", "low-power": return .critical
            default: continue
            }
        }
        return nil
    }

    private static func pressureMultiplier(_ pressure: OrganismResourcePressure) -> Double {
        switch pressure {
        case .nominal: return 1.0
        case .elevated: return 1.25
        case .high: return 1.6
        case .critical: return 2.0
        }
    }
}

// MARK: - The diurnal curve (item 4, 2026-09-02)
//
// Agent's #10: "I know it's 1 AM from a timestamp. A person at 1 AM *feels*
// 1 AM." A timestamp is a fact she reads; this is a number that moves her.
//
// One cosine anchored to the TROUGH — the middle of the user's declared quiet
// window, or the shipped 4 AM default when they never declared one. At the
// trough the curve reads −1, twelve hours later +1. Amplitudes are hard caps
// (both ≤ 0.15 by construction), so the curve is a lean, never a mood.
//
// PURITY: this modulates the PROJECTED chemistry only, exactly like anticipatory
// affect (`OrganismProspectiveAffect.modulate`) — the stored `ChemicalState` is
// never touched, so a clock-less install and a 3 PM projection are byte-identical
// in the store. And the positive arm scales by the value it is raising, so the
// afternoon can lift a curious body but can never manufacture curiosity from
// silence (design law 4: silence is honest).
public enum OrganismCircadian {
    /// Where the night bottoms out when the user declared no quiet window.
    /// 4 AM local — the human circadian trough, and the hour nobody schedules.
    public static let defaultTroughHour = 4.0
    /// Hard cap on the arousal lean the curve publishes. ≤ 0.15 by contract.
    public static let arousalAmplitude = 0.12
    /// Hard cap on the curiosity lean the curve applies. ≤ 0.15 by contract.
    public static let curiosityAmplitude = 0.09

    /// Local seconds since midnight, and the local hour, in the clock's zone.
    static func localHour(_ date: Date, clock: OrganismDiurnalClock) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = clock.timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        return hour + minute / 60 + second / 3_600
    }

    /// The hour the body bottoms out: the midpoint of the declared quiet window
    /// (wrap-aware — 23→7 gives 3 AM), else the shipped default.
    static func troughHour(_ clock: OrganismDiurnalClock) -> Double {
        guard let start = clock.quietStartHour, let end = clock.quietEndHour else {
            return defaultTroughHour
        }
        let span = start < end ? Double(end - start) : Double(24 - start + end)
        return (Double(start) + span / 2).truncatingRemainder(dividingBy: 24)
    }

    /// The read. −1 at the trough, +1 twelve hours later; phase and nightliness
    /// alongside it. Pure.
    public static func read(at date: Date, clock: OrganismDiurnalClock) -> OrganismDiurnalRead {
        let hour = localHour(date, clock: clock)
        let phase = (hour / 24).truncatingRemainder(dividingBy: 1)
        // Signed distance from the trough, wrapped into [−12, 12).
        var offset = hour - troughHour(clock)
        offset = offset.truncatingRemainder(dividingBy: 24)
        if offset < -12 { offset += 24 }
        if offset >= 12 { offset -= 24 }
        let curve = -cos(.pi * offset / 12)
        return OrganismDiurnalRead(
            timeOfDayPhase: phase < 0 ? phase + 1 : phase,
            // 1 at the trough, 0 at the peak — the "it's late and it shows" gate.
            nightliness: (1 - curve) / 2,
            arousalOffset: arousalAmplitude * curve,
            curiosityOffset: curiosityAmplitude * curve
        )
    }

    /// Apply the curiosity half to a PROJECTED chemistry, and return the read
    /// that describes what was applied. Nil clock → unchanged state, nil read.
    ///
    /// The negative arm applies in full (3 AM dulls a curious body); the
    /// positive arm scales by the current value, so 0 stays 0.
    public static func modulate(
        _ state: ChemicalState,
        at date: Date,
        clock: OrganismDiurnalClock?
    ) -> (state: ChemicalState, read: OrganismDiurnalRead?) {
        guard let clock else { return (state, nil) }
        let read = read(at: date, clock: clock)
        var next = state
        let delta = read.curiosityOffset
        next.curiosity = ChemicalState.clamp(
            delta >= 0 ? state.curiosity + delta * state.curiosity : state.curiosity + delta
        )
        return (next, read)
    }
}

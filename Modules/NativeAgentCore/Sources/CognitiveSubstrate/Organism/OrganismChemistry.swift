import Foundation
import PersistenceCore
// Blueprint: | `OrganismChemistry.swift` | `OrganismChemistry` enum; `applying`, `dosedByCaringEvent` |

public enum OrganismChemistry {
    public static func applying(
        signal: SomaticSignal,
        to state: ChemicalState,
        bodySchema: BodySchema,
        elapsedSinceLastSignal: TimeInterval? = nil
    ) -> (chemicalState: ChemicalState, bodySchema: BodySchema) {
        let i = signal.intensity
        // Apply density-capped homeostasis before the signal's own deltas.
        var next = settled(state, rate: settleRate(forElapsed: elapsedSinceLastSignal))
        // Fatigue bypasses signal-driven settling so work cannot rest the body.
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
            // Preserve fatigue above the work ceiling from resource pressure.
            next.fatigue = max(state.fatigue, workFatigueCeiling)
        }
        var body = bodySchema

        switch signal.kind {
        case .userSpoke:
            // Chat valence belongs to substrate appraisal; canonical affect
            // reaches warmth and ambient tenderness through `applyBodySchema`.
            next.curiosity = raise(next.curiosity, by: 0.04 * i)
        case .assistantSpoke:
            // Producing language is not evidence of success, coherence, or
            // confidence. Verified provider/tool/motor outcomes supply those
            // deltas through their own exact signals.
            break
        case .correctionReceived:
            next.vigilance = raise(
                next.vigilance,
                by: relationalVigilanceRaise(0.12 * i, tenderness: state.tenderness)
            )
            // A bare correction is not care; appraised repair earns the same dose as other care.
            next.confidence = lower(next.confidence, by: 0.05 * i)
            next.coherence = lower(next.coherence, by: 0.03 * i)
        case .toolStarted:
            next.urgency = raise(next.urgency, by: 0.04 * i)
            next.agency = raise(next.agency, by: 0.03 * i)
        case .toolSucceeded:
            body.toolCapabilityReading = nil
            body.toolHandsAvailable = true
            next.confidence = raise(next.confidence, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.05 * i)
            next.agency = raise(next.agency, by: 0.04 * i)
            next.urgency = lower(next.urgency, by: 0.07 * i)
            next.vigilance = lower(next.vigilance, by: 0.02 * i)
        case .toolFailed:
            body.toolCapabilityReading = nil
            body.toolHandsAvailable = false
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
        case .deskItemCancelled:
            break
        case .memoryCommitted, .memoryHygieneCompleted:
            body.memoryIntegrityReading = nil
            body.memoryHealthy = true
            next.coherence = raise(next.coherence, by: 0.06 * i)
            next.confidence = raise(next.confidence, by: 0.04 * i)
        case .memoryCorrected:
            body.memoryIntegrityReading = nil
            // Correcting a stored fact is bookkeeping, not evidence of care.
            next.vigilance = raise(next.vigilance, by: 0.08 * i)
            next.confidence = lower(next.confidence, by: 0.03 * i)
        case .dreamCompleted, .remIntegrated:
            body.dreamIntegrityReading = nil
            body.dreamHealthy = true
            next.fatigue = lower(next.fatigue, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.06 * i)
            // Dream completion neither doses nor subtracts tenderness.
        case .iPhoneReachable:
            body.peerPresenceBelief = nil
            body.iPhoneReachable = true
            body.notificationPathHealthy = true
            next.coherence = raise(next.coherence, by: 0.02 * i)
        case .iPhoneStale:
            body.peerPresenceBelief = nil
            body.notificationPathHealthy = false
            body.iPhoneReachable = false
            next.vigilance = raise(next.vigilance, by: 0.04 * i)
        case .phoneDeliveryStarted:
            body.notificationDeliveryBelief = nil
        case .phoneDeliveryReceived:
            body.notificationDeliveryBelief = nil
            body.iPhoneReachable = true
            body.notificationPathHealthy = true
            next.coherence = raise(next.coherence, by: 0.02 * i)
        case .phoneDeliveryFailed:
            body.notificationDeliveryBelief = nil
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
            // Calendar refresh changes horizon rows; anticipation colors only
            // projected chemistry through `OrganismProspectiveAffect.modulate`.
            break
        case .resourcePressureChanged:
            body.resourcePressureReading = nil
            body.resourcePressure = OrganismResourcePressure.from(metadata: signal.metadata) ?? body.resourcePressure
            let pressure = pressureMultiplier(body.resourcePressure)
            next.fatigue = raise(next.fatigue, by: 0.10 * i * pressure)
            next.vigilance = raise(next.vigilance, by: 0.05 * i * pressure)
            next.agency = lower(next.agency, by: 0.04 * i * pressure)
        }

        return (next, body)
    }

    /// `OrganismKernel.foldTurn` admits a fixed caring dose, independent of signal intensity.
    public static func dosedByCaringEvent(_ tenderness: Double) -> Double {
        raise(tenderness, by: OrganismCaringEvent.dose)
    }

    /// Only `.correctionReceived` gets tenderness relief, capped at 25% of its
    /// vigilance raise; tool, provider, verification and safety vigilance stay intact.
    public static let tendernessGuardRelief = 0.25

    static func relationalVigilanceRaise(
        _ amount: Double,
        tenderness: Double
    ) -> Double {
        guard amount > 0 else { return amount }
        return amount * (1 - tendernessGuardRelief * tenderness.clamped01())
    }

    /// Name tenderness on the body line only within this window of a caring turn.
    public static let tenderNamedWindow: TimeInterval = 3 * 3_600

    public static func projection(
        at date: Date,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        diurnal: OrganismDiurnalRead? = nil,
        tenderNamed: Bool = true
    ) -> OrganismReadout {
        OrganismReadout(
            generatedAt: date,
            bodyLine: bodyLine(
                chemicalState: chemicalState,
                bodySchema: bodySchema,
                diurnal: diurnal,
                tenderNamed: tenderNamed
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

        // The compatibility Bool maps unknown provider evidence to false;
        // typed evidence keeps unknown from counting as failure or recovery.
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

    /// Memory brittleness requires current typed evidence; the persisted Bool
    /// alone cannot establish failure. Unknown withholds both alarm and health.
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
            if reading.metrics.uncertainty >= memoryBeliefUncertaintyCeiling { return nil }
            if reading.metrics.freshness < memoryBeliefFreshnessFloor { return nil }
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
        diurnal: OrganismDiurnalRead? = nil,
        tenderNamed: Bool = true
    ) -> String? {
        if bodySchema.resourcePressure == .critical {
            return "- Body: the Mac is under thermal pressure; keep the next move lightweight."
        }
        if let tired = fatigueBodyLine(chemicalState.fatigue, diurnal: diurnal) {
            return tired
        }
        if observedProviderHealth(bodySchema) == false
            || !bodySchema.toolHandsAvailable {
            return "- Body: provider or tool path feels brittle; be careful before claiming completion."
        }
        // Vigilance can express anticipation; only path evidence can claim brittleness.
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
        return positiveBodyLine(chemicalState, tenderNamed: tenderNamed)
    }

    /// At fatigue >= 0.24, name tiredness once, preferring night near the trough.
    /// Keep phrases free of digits and implementation terms for the capsule sanitizer.
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
    static func positiveBodyLine(_ c: ChemicalState, tenderNamed: Bool = true) -> String? {
        func band(_ v: Double, _ low: String, _ mid: String, _ high: String) -> String {
            v >= 0.6 ? high : (v >= 0.4 ? mid : low)
        }
        var felt: [(weight: Double, phrase: String)] = []
        if c.warmth >= 0.22 {
            felt.append((c.warmth, band(c.warmth, "quietly warm and steady", "warm and steady", "warm and open")))
        }
        if tenderNamed, c.tenderness >= 0.22 {
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
            // "high"; grade within the gated range instead.
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

    /// Positive raises scale by remaining headroom / `axisHighRail`; `lower`
    /// mirrors this against the floor by scaling positive decreases by the current value.
    public static func raise(_ current: Double, by amount: Double) -> Double {
        // A non-positive "raise" is a plain add (a negative amount lowers);
        // only the positive branch saturates toward the ceiling.
        guard amount > 0 else { return (current + amount).clamped01() }
        let headroom = max(0, axisHighRail - current.clamped01()) / axisHighRail
        return min(axisHighRail, (current + amount * headroom).clamped01())
    }

    /// The most any raised axis may hold. Below it there is always somewhere
    /// left to go, which is what makes the next success mean something.
    public static let axisHighRail = 0.94

    static func lower(_ current: Double, by amount: Double) -> Double {
        guard amount > 0 else { return (current - amount).clamped01() }
        return (current - amount * current.clamped01()).clamped01()
    }

    /// `applyBodySchema` integrates canonical `socialWarmth` at or above this gate over
    /// elapsed crossing time, never read count: approach = 1 - exp(-window / tau),
    /// with a 45-minute fill constant and at most one hour integrated per crossing.
    static let tendernessWarmthGate = 0.45
    static let tendernessTimeConstant: TimeInterval = 45 * 60
    static let maximumTendernessIntegrationWindow: TimeInterval = 60 * 60

    /// The ambient target is at most 0.20, below the 0.22 felt-word gate; caring moments supply the main term.
    public static let tendernessWarmthContribution = 0.20

    public static func tenderness(
        _ current: Double,
        underCanonicalWarmth warmth: Double,
        elapsed: TimeInterval
    ) -> Double {
        let clamped = current.clamped01()
        guard warmth >= tendernessWarmthGate else { return clamped }
        let window = min(max(0, elapsed), maximumTendernessIntegrationWindow)
        guard window > 0, tendernessTimeConstant > 0 else { return clamped }
        // Approach the earned share without overshoot; this path never subtracts.
        let target = warmth.clamped01() * tendernessWarmthContribution
        guard target > clamped else { return clamped }
        let approach = 1 - exp(-window / tendernessTimeConstant)
        return (clamped + (target - clamped) * approach).clamped01()
    }

    /// `OrganismPersistentState.decayed` alone spends tenderness's three-day
    /// wall-clock half-life, shared by live settling and cold-start load regardless of traffic.
    public static let tendernessHalfLife: TimeInterval = 3 * 24 * 3_600

    /// Per-signal ceiling on the share of the gap to rest that settling may spend.
    public static let perSignalSettleRate = 0.006

    /// Hourly settling ceiling at any density: alone, ln(2)/0.20 ~= 3.47 h;
    /// with persistence's 0.78^h / 0.92^h decay, holds are ~93 / ~147 minutes,
    /// both above the affect layer's 90-minute socialWarmth hold.
    public static let maximumSettlePerHour = 0.20

    /// min(per-signal ceiling, hourly ceiling * elapsed hours); nil uses the
    /// per-signal ceiling without a density claim. The kernel supplies local ingestion gaps.
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
            (value + (target - value) * rate).clamped01()
        }
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

    // MARK: - Fatigue

    // Work accrual saturates through `raise`; fatigue is a feeling, never a
    // posture, tool-strategy or loop-budget gate.

    /// Base fatigue share per admitted work signal, before weight and intensity.
    public static let perSignalFatigueAccrual = 0.0015
    /// Maximum work-fatigue accrual per wall-hour at any traffic density.
    public static let maximumFatigueAccrualPerHour = 0.05
    /// Work-fatigue ceiling; thermal pressure may exceed it.
    public static let workFatigueCeiling = 0.6
    /// Quiet half-life, slower than generic quick decay and the 90-minute socialWarmth hold.
    public static let fatigueRelaxationHalfLife: TimeInterval = 6 * 3_600

    /// Only admitted work kinds accrue; lifecycle, reachability, dreams and approvals cost nothing.
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

    /// min(weight * clamped intensity * base share, hourly cap * elapsed hours);
    /// nil elapsed uses the signal share without a density claim.
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

    // The kernel accrues wakefulness only across live elapsed time, regardless
    // of quiet hours, and resets the separately tracked share on dream completion.

    /// Fatigue per wall-hour awake, before the share cap and quiet relaxation.
    public static let wakefulnessAccrualPerHour = 0.012
    /// Wakefulness's separate cap stays below the 0.24 body-line and 0.35 worn-down gates.
    public static let wakefulnessShareCap = 0.20
    /// Gaps of seven hours or more accrue nothing and only relax; shorter quiet gaps count as awake.
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
        return ((relaxed + gain).clamped01(), gain)
    }

    /// Quiet fatigue follows value * 0.5^(elapsed / half-life).
    public static func relaxedFatigue(_ value: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, fatigueRelaxationHalfLife > 0 else {
            return value.clamped01()
        }
        return (value * pow(0.5, elapsed / fatigueRelaxationHalfLife)).clamped01()
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

// MARK: - The diurnal curve

// The local clock colors projected chemistry; stored state is untouched.
public enum OrganismCircadian {
    /// Where the night bottoms out when the user declared no quiet window.
    /// 4 AM local — the human circadian trough, and the hour nobody schedules.
    public static let defaultTroughHour = 4.0
    /// Hard cap on the arousal lean the curve publishes. ≤ 0.15 by contract.
    public static let arousalAmplitude = 0.12
    /// Hard cap on the curiosity lean the curve applies. ≤ 0.15 by contract.
    public static let curiosityAmplitude = 0.09

    /// Fractional local hour in the Mac's current time zone.
    static func localHour(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
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
        let hour = localHour(date)
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
        next.curiosity = (
            delta >= 0 ? state.curiosity + delta * state.curiosity : state.curiosity + delta
        ).clamped01()
        return (next, read)
    }
}

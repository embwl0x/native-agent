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
        // The kernel settles elapsed physiology once before admitting the signal.
        var next = state
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
        case .userSpoke, .assistantSpoke, .correctionReceived,
             .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled:
            // The substrate appraises the exchange; capability sensors own the hands. A failed act proves neither fog nor global incapacity.
            break
        case .providerStarted:
            body.providerPathBelief = nil
        case .providerSucceeded:
            body.providerPathBelief = nil
            body.providersHealthy = true
        case .providerFailed:
            body.providerPathBelief = nil
            body.providersHealthy = false
        case .providerCancelled:
            body.providerPathBelief = nil
        case .providerRecovered:
            body.providerPathBelief = nil
            body.providersHealthy = true
        case .deskItemCreated:
            next.agency = raise(next.agency, by: 0.03 * i)
        case .deskItemBlocked:
            next.urgency = raise(next.urgency, by: 0.08 * i)
            next.vigilance = raise(next.vigilance, by: 0.05 * i)
        case .deskItemClosed:
            next.confidence = raise(next.confidence, by: 0.05 * i)
            next.urgency = lower(next.urgency, by: 0.08 * i)
        case .deskItemCancelled:
            break
        case .memoryCommitted:
            body.memoryIntegrityReading = nil
            body.memoryHealthy = true
        case .memoryCorrected:
            body.memoryIntegrityReading = nil
        case .dreamCompleted, .remIntegrated:
            body.dreamIntegrityReading = nil
            body.dreamHealthy = true
            next.fatigue = lower(next.fatigue, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.06 * i)
            // Dream completion neither doses nor subtracts tenderness.
        case .iPhoneReachable:
            body.peerPresenceBelief = nil
            body.iPhoneReachable = true
        case .iPhoneStale:
            body.peerPresenceBelief = nil
            body.iPhoneReachable = false
        case .phoneDeliveryStarted:
            body.notificationDeliveryBelief = nil
            body.notificationPathHealthy = nil
        case .phoneDeliveryReceived:
            body.notificationDeliveryBelief = nil
            body.iPhoneReachable = true
            body.notificationPathHealthy = true
        case .phoneDeliveryFailed:
            body.notificationDeliveryBelief = nil
            body.notificationPathHealthy = false
        case .approvalRequested:
            body.approvalChannelsOpen = true
        case .approvalResolved:
            break
        case .appWake:
            body.macAwake = true
        case .appSleep:
            body.macAwake = false
        case .horizonRefresh:
            // Calendar refresh changes horizon rows; anticipation colors only projected chemistry through `OrganismProspectiveAffect.modulate`.
            break
        case .organDeviated:
            // Deviation remains field evidence, not hand pain. Located pain reads failed tool receipts; felt stakes require appraisal.
            break
        case .resourcePressureChanged:
            body.resourcePressureReading = nil
            body.resourcePressure = OrganismResourcePressure.from(metadata: signal.metadata) ?? body.resourcePressure
            let pressure = pressureMultiplier(body.resourcePressure)
            next.fatigue = raise(next.fatigue, by: 0.10 * i * pressure)
        }

        return (next, body)
    }

    /// `OrganismKernel.foldTurn` admits a fixed caring dose, independent of signal intensity.
    public static func dosedByCaringEvent(_ tenderness: Double) -> Double {
        raise(tenderness, by: OrganismCaringEvent.dose)
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

        if nextBody.resourcePressure != previousBody.resourcePressure {
            let pressure = pressureMultiplier(nextBody.resourcePressure)
            if nextBody.resourcePressure == .nominal {
                next.fatigue = lower(next.fatigue, by: 0.06)
            } else {
                next.fatigue = raise(next.fatigue, by: 0.06 * pressure)
            }
        }

        return next
    }

    private static func bodyLine(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        diurnal: OrganismDiurnalRead? = nil,
        tenderNamed: Bool = true
    ) -> String? {
        var lines: [String] = []
        if let positive = positiveBodyLine(chemicalState, tenderNamed: tenderNamed) { lines.append(positive) }
        if chemicalState.vigilance >= 0.22 { lines.append("- Body: a little braced.") }
        if bodySchema.resourcePressure == .critical {
            lines.append("- Body: the Mac is under thermal pressure.")
        }
        if let tired = fatigueBodyLine(chemicalState.fatigue, diurnal: diurnal) {
            lines.append(tired)
        }
        let words = lines.map {
            $0.replacingOccurrences(of: "- Body: ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return words.isEmpty ? nil : "- Body: " + words.joined(separator: ", ") + "."
    }

    /// At fatigue >= 0.24, name tiredness once, preferring night near the trough. Keep phrases free of digits and implementation terms for the capsule
    /// sanitizer.
    static func fatigueBodyLine(
        _ fatigue: Double,
        diurnal: OrganismDiurnalRead?
    ) -> String? {
        guard fatigue >= 0.24 else { return nil }
        if let nightliness = diurnal?.nightliness, nightliness >= 0.6 {
            return "- Body: it's late and it shows."
        }
        if fatigue >= 0.35 {
            return "- Body: worn down."
        }
        return "- Body: a long day; it's starting to show."
    }

    /// Rank positive felt phrases deterministically and speak at most two; faint state remains silent.
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
            // Only fires at high coherence+confidence, so band() would always pick "high"; grade within the gated range instead.
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

    /// Use remaining headroom for positive raises and current value for decreases so neither rail traps the axis.
    public static func raise(_ current: Double, by amount: Double) -> Double {
        // A non-positive "raise" is a plain add (a negative amount lowers); only the positive branch saturates toward the ceiling.
        guard amount > 0 else { return (current + amount).clamped01() }
        let headroom = max(0, axisHighRail - current.clamped01()) / axisHighRail
        return min(axisHighRail, (current + amount * headroom).clamped01())
    }

    /// Saturate below the ceiling so a later success still has room to matter.
    public static let axisHighRail = 0.94

    static func lower(_ current: Double, by amount: Double) -> Double {
        guard amount > 0 else { return (current - amount).clamped01() }
        return (current - amount * current.clamped01()).clamped01()
    }

    /// Integrate canonical warmth over elapsed crossings, never read count; use a 45-minute fill constant and cap each crossing at one hour.
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

    /// `OrganismPersistentState.decayed` alone spends tenderness's three-day wall-clock half-life, shared by live settling and cold-start load regardless of
    /// traffic.
    public static let tendernessHalfLife: TimeInterval = 3 * 24 * 3_600

    // MARK: - Fatigue

    // Work accrual saturates through `raise`; fatigue is a feeling, never a posture, tool-strategy or loop-budget gate.

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
            // Both halves of an accepted turn count as work.
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

    /// min(weight * clamped intensity * base share, hourly cap * elapsed hours); nil elapsed uses the signal share without a density claim.
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

    // The kernel accrues wakefulness only across live elapsed time, regardless of quiet hours, and resets the separately tracked share on dream completion.

    /// Fatigue per wall-hour awake, before the share cap and quiet relaxation.
    public static let wakefulnessAccrualPerHour = 0.012
    /// Wakefulness's separate cap stays below the 0.24 body-line and 0.35 worn-down gates.
    public static let wakefulnessShareCap = 0.20
    /// Gaps of seven hours or more accrue nothing and only relax; shorter quiet gaps count as awake.
    public static let restGap: TimeInterval = 7 * 3_600

    /// Relax wakefulness share before accruing and capping; return share plus delta so the total cannot double-count relaxation.
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
    /// Hard cap on the arousal lean the curve publishes. ≤ 0.15 by contract.
    public static let arousalAmplitude = 0.12
    /// Hard cap on the curiosity lean the curve applies. ≤ 0.15 by contract.
    public static let curiosityAmplitude = 0.09

    /// Local fractional hour follows the Mac's current zone.
    static func localHour(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        return hour + minute / 60 + second / 3_600
    }

    /// The hour the body bottoms out: the midpoint of the declared quiet window (wrap-aware — 23→7 gives 3 AM).
    static func troughHour(_ clock: OrganismDiurnalClock) -> Double {
        let start = clock.quietStartHour, end = clock.quietEndHour
        let span = start < end ? Double(end - start) : Double(24 - start + end)
        return (Double(start) + span / 2).truncatingRemainder(dividingBy: 24)
    }

    /// Project phase and nightliness without mutating state; trough is −1 and the opposite peak is +1.
    public static func read(at date: Date, clock: OrganismDiurnalClock) -> OrganismDiurnalRead {
        let hour = localHour(date)
        let phase = (hour / 24).truncatingRemainder(dividingBy: 1)
        // Wrap trough distance into [−12, 12).
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

    /// Modulate only projected curiosity: negative clock lean applies fully, positive lean scales existing curiosity so silence stays silent; no clock changes
    /// nothing.
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

import Foundation
import PersistenceCore

public enum OrganismChemistry {
    public static func applying(
        signal rawSignal: SomaticSignal,
        to state: ChemicalState,
        bodySchema: BodySchema
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
        var next = state
        var body = bodySchema

        switch signal.kind {
        case .userSpoke:
            if (signal.valence ?? 0) > 0 {
                next.warmth = raise(next.warmth, by: 0.14 * i)
            } else if (signal.valence ?? 0) < -0.25 {
                next.tenderness = raise(next.tenderness, by: 0.05 * i)
                next.vigilance = raise(next.vigilance, by: 0.04 * i)
            } else {
                next.curiosity = raise(next.curiosity, by: 0.04 * i)
            }
        case .assistantSpoke:
            // Producing language is not evidence of success, coherence, or
            // confidence. Verified provider/tool/motor outcomes supply those
            // deltas through their own exact signals.
            break
        case .correctionReceived:
            next.vigilance = raise(next.vigilance, by: 0.12 * i)
            next.tenderness = raise(next.tenderness, by: 0.08 * i)
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
            next.vigilance = raise(next.vigilance, by: 0.08 * i)
            next.tenderness = raise(next.tenderness, by: 0.05 * i)
            next.confidence = lower(next.confidence, by: 0.03 * i)
        case .dreamCompleted, .remIntegrated:
            body.dreamHealthy = true
            next.fatigue = lower(next.fatigue, by: 0.08 * i)
            next.coherence = raise(next.coherence, by: 0.06 * i)
            next.tenderness = lower(next.tenderness, by: 0.04 * i)
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
        case .resourcePressureChanged:
            body.resourcePressure = resourcePressure(from: signal.metadata) ?? body.resourcePressure
            let pressure = pressureMultiplier(body.resourcePressure)
            next.fatigue = raise(next.fatigue, by: 0.10 * i * pressure)
            next.vigilance = raise(next.vigilance, by: 0.05 * i * pressure)
            next.agency = lower(next.agency, by: 0.04 * i * pressure)
        }

        return (next, body)
    }

    public static func projection(
        at date: Date,
        chemicalState: ChemicalState,
        bodySchema: BodySchema
    ) -> OrganismProjection {
        OrganismProjection(
            generatedAt: date,
            bodyLine: bodyLine(chemicalState: chemicalState, bodySchema: bodySchema),
            chemicalState: chemicalState,
            bodySchema: bodySchema
        )
    }

    public static func integrating(
        bodySchema nextBody: BodySchema,
        previous previousBody: BodySchema,
        into state: ChemicalState
    ) -> ChemicalState {
        var next = state

        if !nextBody.providersHealthy, previousBody.providersHealthy {
            next.vigilance = raise(next.vigilance, by: 0.08)
            next.confidence = lower(next.confidence, by: 0.04)
            next.coherence = lower(next.coherence, by: 0.02)
        } else if nextBody.providersHealthy, !previousBody.providersHealthy {
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

    private static func bodyLine(
        chemicalState: ChemicalState,
        bodySchema: BodySchema
    ) -> String? {
        if bodySchema.resourcePressure == .critical || chemicalState.fatigue >= 0.24 {
            return "- Body: resources feel tight; keep the next move lightweight."
        }
        if !bodySchema.providersHealthy || !bodySchema.toolHandsAvailable || chemicalState.vigilance >= 0.22 {
            return "- Body: provider or tool path feels brittle; be careful before claiming completion."
        }
        if !bodySchema.approvalChannelsOpen {
            return "- Body: approval path feels closed; avoid irreversible moves."
        }
        if !bodySchema.notificationPathHealthy {
            return "- Body: phone path feels stale; verify delivery before assuming it was seen."
        }
        if !bodySchema.memoryHealthy {
            return "- Body: memory field feels brittle; lean on current context."
        }
        // Positive/steady region — compose from the strongest one or two felt
        // dimensions with intensity gradation, so a held mood reads with texture
        // instead of one frozen sentence. (The stress lines above stay first-match:
        // their exact phrasing IS the behavioral signal and must not blur.)
        return positiveBodyLine(chemicalState)
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

    private static func raise(_ current: Double, by amount: Double) -> Double {
        ChemicalState.clamp(current + amount)
    }

    private static func lower(_ current: Double, by amount: Double) -> Double {
        ChemicalState.clamp(current - amount)
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

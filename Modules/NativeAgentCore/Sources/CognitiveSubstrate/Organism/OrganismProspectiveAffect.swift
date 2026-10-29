// Anticipation derives bounded projected chemistry from predictions without changing stored state; an empty ledger is inert.

import Foundation

// Blueprint: | `OrganismProspectiveAffect.swift` | `OrganismProspectiveAffect`: pure prediction/horizon modulation of projected chemistry, without changing stored chemical state |

enum OrganismProspectiveAffect {

    // MARK: - Tuning knobs (the ONE prospective surface)

    /// Total reach of anticipation on any single dim — an undertone, never a mood.
    static let maxDelta = 0.15
    /// A prediction only weighs on her once it is within this window of due.
    static let anticipationWindow: TimeInterval = 10 * 60
    /// A recent violation keeps the body braced for this long (fading).
    static let violationShadowHalfLife: TimeInterval = 20 * 60

    // MARK: - The horizon's share of anticipation
    // Horizons use a wider window within the existing per-dimension budget, never a second allowance.

    /// A horizon weighs from a week out, growing as it nears.
    static let horizonWindow: TimeInterval = OrganismHorizonRegister.maximumHorizon
    /// Looking forward is warm as well as curious, but less warm than curious —
    /// an undertone in the dim that carries the most social meaning, so it never
    /// manufactures affection out of a calendar.
    static let horizonWarmthShare = 0.5

    /// A horizon row's share of looking-forward / dread. Pure; nil payload or a
    /// horizon still a week out contributes nothing.
    ///
    /// Nearness is linear in the distance to due and FULL once overdue: a thing
    /// that should have happened and has not is exactly when a person feels it
    /// most. Valence decides which register it lands in — she does not brace
    /// for Friday and she does not look forward to the call.
    static func horizonContribution(
        _ p: OrganismPrediction,
        at now: Date
    ) -> (toward: Double, dread: Double) {
        guard let horizon = p.horizon else { return (0, 0) }
        let untilDue = p.dueAt.timeIntervalSince(now)
        let nearness = untilDue <= 0 ? 1.0 : max(0, 1 - untilDue / horizonWindow)
        guard nearness > 0 else { return (0, 0) }
        let magnitude = nearness * abs(horizon.valence)
        guard magnitude > 0 else { return (0, 0) }
        return horizon.valence > 0 ? (magnitude, 0) : (0, magnitude)
    }

    /// Modulate a chemical state with what's PENDING. Pure: same inputs → same
    /// output; empty/idle ledger → the input state unchanged.
    static func modulate(
        _ state: ChemicalState,
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> ChemicalState {
        let pending = ledger.predictions.values.filter {
            $0.status == .pending && carriesFeeling($0.kind)
        }
        // Violation shadow: a recently violated expectation keeps a fading edge of
        // wariness even between predictions (the body remembers the last miss).
        let shadow = violationShadow(ledger, at: now)
        guard !pending.isEmpty || shadow > 0.01 else { return state }

        var bracing = 0.0        // → vigilance up, confidence down
        var lookingForward = 0.0 // → curiosity up
        var horizonToward = 0.0  // item 5 → curiosity + warmth
        var horizonDread = 0.0   // item 5 → vigilance
        for p in pending {
            let contribution = predictionBracingContribution(p, ledger: ledger, at: now)
            bracing += contribution.bracing
            lookingForward += contribution.lookingForward
            let horizon = horizonContribution(p, at: now)
            horizonToward += horizon.toward
            horizonDread += horizon.dread
        }
        bracing = min(1, bracing + shadow)
        lookingForward = min(1, lookingForward)
        horizonToward = min(1, horizonToward)
        horizonDread = min(1, horizonDread)

        var out = state
        // Item 5 rides INSIDE the existing per-dim budget (the inner `min(1,…)`),
        // so vigilance and curiosity can still move at most `maxDelta` in total
        // however many rows are open. Confidence and urgency stay on `bracing`
        // alone: dreading Friday should not make her doubt her hands or feel
        // late. With no horizon rows both terms are 0 and every line below is
        // byte-identical to what it was.
        out.vigilance = (out.vigilance + maxDelta * min(1, bracing + horizonDread)).clamped01()
        out.confidence = (out.confidence - maxDelta * bracing * 0.7).clamped01()
        out.curiosity = (out.curiosity + maxDelta * min(1, lookingForward + horizonToward)).clamped01()
        out.urgency = (out.urgency + maxDelta * bracing * 0.5).clamped01()
        out.warmth = (out.warmth + maxDelta * horizonWarmthShare * horizonToward).clamped01()
        return out
    }

    static func carriesFeeling(_ kind: OrganismPredictionKind) -> Bool {
        switch kind {
        case .toolCompletion, .providerCompletion, .phoneDelivery: return false
        case .approvalResolution, .workflowAdvance, .semanticExpectation: return true
        }
    }

    /// Projection-time anticipation and resolution-time relief share the same per-prediction contribution.
    static func predictionBracingContribution(
        _ p: OrganismPrediction,
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> (bracing: Double, lookingForward: Double) {
        // Item 5: a horizon row is not plumbing. Its anticipation is measured by
        // `horizonContribution` on a seven-day window; running it through the
        // ten-minute path as well would double-count it and, worse, read a
        // week-away Friday as a near-due low-confidence expectation about her
        // own wiring.
        guard p.horizon == nil else { return (0, 0) }
        // Nearness: full weight inside the window, fading with distance to due;
        // an overdue pending prediction weighs FULLY (the outcome is late).
        let untilDue = p.dueAt.timeIntervalSince(now)
        let nearness = untilDue <= 0
            ? 1.0
            : max(0, 1 - untilDue / anticipationWindow)
        guard nearness > 0 else { return (0, 0) }
        // Expected outcome: the body's learned confidence for this path kind,
        // blended with the prediction's own confidence/uncertainty.
        let pathConfidence = pathConfidence(for: p.kind, in: ledger.bodyConfidence)
        let expectation = 0.5 * pathConfidence + 0.5 * p.confidence
        if expectation < 0.5 {
            return (nearness * (0.5 - expectation) * 2 * (0.6 + 0.4 * p.uncertainty), 0)
        }
        return (0, nearness * (expectation - 0.5) * 2 * 0.6)
    }

    /// The fading wariness a recent violation leaves behind — extracted so
    /// resolution-time relief includes the ambient dread, not just the
    /// prediction's own shortfall.
    static func violationShadow(_ ledger: OrganismPredictionLedger, at now: Date) -> Double {
        guard let lastViolation = ledger.lastFeltViolationAt else { return 0 }
        let age = max(0, now.timeIntervalSince(lastViolation))
        return 0.5 * pow(0.5, age / violationShadowHalfLife)
    }

    static func pathConfidence(
        for kind: OrganismPredictionKind,
        in confidence: OrganismBodyConfidence
    ) -> Double {
        switch kind {
        case .toolCompletion: return confidence.toolPath
        case .providerCompletion: return confidence.providerPath
        case .phoneDelivery: return confidence.phonePath
        case .approvalResolution: return confidence.approvalPath
        case .workflowAdvance: return confidence.workflowPath
        // A semantic expectation has no body path; its prior is even odds.
        case .semanticExpectation: return 0.5
        }
    }

    // MARK: - Pending tool expectations
    // Only pending tool completions contribute bounded, meaningful group words to Fluid Context query terms.

    /// Sorted, bounded tool groups follow ledger liveness: pending counts past dueAt, resolved and expired do not.
    static func predictedToolGroups(
        ledger: OrganismPredictionLedger,
        limit: Int = 8
    ) -> Set<String> {
        var groups: Set<String> = []
        for prediction in ledger.predictions.values {
            guard prediction.status == .pending else { continue }   // unresolved + not .expired
            guard prediction.kind == .toolCompletion else { continue } // TOOL-shaped only
            guard let group = toolGroup(fromSourceOrgan: prediction.sourceOrgan) else { continue }
            groups.insert(group)
        }
        guard limit >= 0 else { return [] }
        guard groups.count > limit else { return groups }
        return Set(groups.sorted().prefix(limit))
    }

    /// Parse the canonicalized `tool.<toolName>` sourceOrgan into a group word.
    /// Returns nil for anything that is not tool-shaped (defensive — the kind gate
    /// should already have excluded these).
    private static func toolGroup(fromSourceOrgan sourceOrgan: String) -> String? {
        let token = sourceOrgan.lowercased()
        guard token == "tool" || token.hasPrefix("tool-") else { return nil }
        let remainder = token == "tool" ? "" : String(token.dropFirst("tool-".count))
        let segments = remainder.split(separator: "-").map(String.init)
        guard let family = segments.first, !family.isEmpty else { return "tools" }

        switch family {
        case "git": return "git"
        case "recall", "commit": return "memory"
        // Verb-prefixed tools map to the content word their outputs share.
        case "read", "write", "list", "glob", "grep", "apply": return "files"
        case "shell", "bash", "exec": return "shell"
        case "invoke": return "agents"
        case "mac":
            // mac_<domain>_* — the domain segment (calendar/reminders/spotlight/focus/
            // notify/quit) is the content word; "mac" alone matches nothing useful.
            if segments.count >= 2, !segments[1].isEmpty { return segments[1] }
            return "mac"
        default:
            return family
        }
    }
}

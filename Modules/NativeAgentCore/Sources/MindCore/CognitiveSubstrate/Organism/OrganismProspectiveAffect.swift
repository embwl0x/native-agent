// Anticipation derives bounded projected chemistry from predictions without changing stored state; an empty ledger is inert.

import Foundation

// Blueprint: | `OrganismProspectiveAffect.swift` | `OrganismProspectiveAffect`: pure prediction/horizon chemistry projection |

enum OrganismProspectiveAffect {

    // MARK: - Tuning knobs (the ONE prospective surface)

    /// Bound anticipation to an undertone on each axis so predictions cannot replace mood.
    static let maxDelta = 0.15
    /// Only near-due predictions contribute anticipation.
    static let anticipationWindow: TimeInterval = 10 * 60
    /// A recent violation leaves a fading brace.
    static let violationShadowHalfLife: TimeInterval = 20 * 60

    // MARK: - The horizon's share of anticipation
    // Horizons use a wider window within the existing per-dimension budget, never a second allowance.

    /// Horizon anticipation grows over one week toward due time.
    static let horizonWindow: TimeInterval = OrganismHorizonRegister.maximumHorizon
    /// Keep horizon warmth weaker than curiosity so calendar anticipation cannot manufacture affection.
    static let horizonWarmthShare = 0.5

    /// Nearness reaches full weight when overdue; guessed valence selects looking forward or dread, never a measured outcome.
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

    /// Modulate a chemical state with what's PENDING. Pure: same inputs → same output; empty/idle ledger → the input state unchanged.
    static func modulate(
        _ state: ChemicalState,
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> ChemicalState {
        let pending = ledger.predictions.values.filter {
            $0.status == .pending && carriesFeeling($0.kind)
        }
        // Violation shadow: a recently violated expectation keeps a fading edge of wariness even between predictions (the body remembers the last miss).
        let shadow = violationShadow(ledger, at: now)
        guard !pending.isEmpty || shadow > 0.01 else { return state }

        var bracing = 0.0
        var lookingForward = 0.0
        var horizonToward = 0.0
        var horizonDread = 0.0
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
        // Horizons share the per-axis budget; confidence and urgency remain operational so dread cannot become doubt about capability.
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
        // Horizon anticipation uses its seven-day rule alone; the operational ten-minute path would double-count and misread calendar evidence.
        guard p.horizon == nil else { return (0, 0) }
        // Nearness: full weight inside the window, fading with distance to due; an overdue pending prediction weighs FULLY (the outcome is late).
        let untilDue = p.dueAt.timeIntervalSince(now)
        let nearness = untilDue <= 0
            ? 1.0
            : max(0, 1 - untilDue / anticipationWindow)
        guard nearness > 0 else { return (0, 0) }
        // Expected outcome: the body's learned confidence for this path kind, blended with the prediction's own confidence/uncertainty.
        let pathConfidence = pathConfidence(for: p.kind, in: ledger.bodyConfidence)
        let expectation = 0.5 * pathConfidence + 0.5 * p.confidence
        if expectation < 0.5 {
            return (nearness * (0.5 - expectation) * 2 * (0.6 + 0.4 * p.uncertainty), 0)
        }
        return (0, nearness * (expectation - 0.5) * 2 * 0.6)
    }

    /// The fading wariness a recent violation leaves behind — extracted so resolution-time relief includes the ambient dread, not just the prediction's own
    /// shortfall.
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
            guard prediction.status == .pending else { continue }
            guard prediction.kind == .toolCompletion else { continue }
            guard let group = toolGroup(fromSourceOrgan: prediction.sourceOrgan) else { continue }
            groups.insert(group)
        }
        guard limit >= 0 else { return [] }
        guard groups.count > limit else { return groups }
        return Set(groups.sorted().prefix(limit))
    }

    /// Only canonical `tool.<toolName>` organs supply context group words.
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
            // Use the domain from mac_<domain>_* tools because the mac prefix alone carries no topic.
            if segments.count >= 2, !segments[1].isEmpty { return segments[1] }
            return "mac"
        default:
            return family
        }
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+SemanticAppraisal.swift` | `SemanticAppraisal`: meaning-weighted event appraisal against outcomes and embedding-touched cares |

/// The appraised MEANING of one event, all dims computable without suspension.
struct SemanticAppraisal: Sendable, Equatable {
    var goalRelevance = 0.0          // 0…1  — does this matter to what she's doing
    var goalCongruence = 0.0         // −1…1 — did it go WITH or AGAINST the goal
    var selfAgency = 0.0             // −1…1 — who caused it (self/tool + , user −)
    var novelty = 0.0                // 0…1  — how unexpected/new
    var copingPotential = 0.0        // −1…1 — can she handle/repair from here
    var relationshipStake = 0.0      // 0...1 -- is the user-Agent relationship implicated
    var relationshipCongruence = 0.0 // −1…1 — how it landed relationally
    var resolutionEvidence = 0.0     // 0…1  — did something actually RESOLVE
    var effortEvidence = 0.0         // 0…1  — was the stretch effortful
    // Signed real movement of the closest touched care with a stance.
    var worldviewStance = 0.0        // −1…1 — toward or away from what she cares about
    var worldviewConflict = 0.0      // 0…1  — how far that care moved away

    static let neutral = SemanticAppraisal()
}

extension CognitiveSubstrate {

    // MARK: - Tuning knobs (the ONE semantic-appraisal surface)

    static let appraisalGoalRelevanceWeight = 0.22
    static let appraisalCopingWeight = 0.10
    static let appraisalAgencyWeight = 0.08
    static let appraisalRelationshipWeight = 0.14
    static let appraisalNoveltyBadWeight = 0.06
    /// Movement away from a touched care adds to the generic valence read.
    static let appraisalWorldviewConflictWeight = 0.06
    static let appraisalWorldviewStanceCongruenceGain = 0.15
    /// assistantTurnCompleted outcome band — replaces the flat +0.25 metronome.
    static let appraisalCompletionBaseFloor = -0.10
    static let appraisalCompletionBaseCeiling = 0.14
    /// How far back peekNodes evidence looks for continuity/resolution/failure reads.
    static let appraisalEvidenceWindow: TimeInterval = 45 * 60

    // MARK: - Derivation (pure, no suspension points)

    /// Appraise `event` against her current state. `post` is the affect state the
    /// event just produced (the same one being stamped). Reads only actor state
    /// that is synchronously available.
    /// Consumes the admitted event's supplied appraisal and warmth boost.
    func semanticAppraisal(
        for event: CognitiveEvent,
        post: CognitiveAffectState,
        precomputedAppraisal: AffectAppraisal,
        precomputedWarmthBoost: Double,
        precomputedCares touchedCares: [CognitiveCare]
    ) -> SemanticAppraisal {
        let now = dependencies.now()
        // Text-derived appraisal reads only user-authored words, never her replies or tool output.
        let text = precomputedAppraisal
        let nodes = field.peekNodes()
        let recent = nodes.filter {
            let age = now.timeIntervalSince($0.lastActivatedAt)
            return age >= 0 && age <= Self.appraisalEvidenceWindow
        }

        var a = SemanticAppraisal()

        // -- outcome sign + evidence reads shared by several dims --------------
        let outcomeSign = Double(event.terminalOutcomePolarity)
        // Tool outcome polarity reads status text, never mood-colored stamped valence.
        let toolObs = recent.filter { $0.kind == .toolObservation }
            .sorted { $0.lastActivatedAt < $1.lastActivatedAt }
        func outcome(_ node: CognitiveNode) -> Int {
            if case .string(let rawKind)? = node.metadata["eventKind"],
               let kind = CognitiveEventKind(rawValue: rawKind) {
                switch kind {
                case .toolSucceeded: return 1
                case .toolFailed, .providerFailure: return -1
                case .toolStarted, .toolCancelled: return 0
                default: break
                }
            }
            if case .string(let rawVerification)? = node.metadata["verification"] {
                switch rawVerification.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "satisfied", "verified", "succeeded": return 1
                case "failed", "rejected", "blocked": return -1
                default: break
                }
            }
            if case .string(let rawStatus)? = node.metadata["status"] {
                switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "completed", "done", "succeeded", "ok": return 1
                case "failed", "blocked": return -1
                case "cancelled", "canceled", "pending", "running", "queued": return 0
                default: break
                }
            }
            // Historical nodes predate typed event metadata. Keep a bounded
            // lexical fallback for replay compatibility only.
            let t = node.summary.lowercased()
            if containsAny(t, ["passed", "succeeded", "success", "complete", "fixed", "resolved", "shipped"]) { return 1 }
            if containsAny(t, ["failed", "failure", "error", "timeout", "timed out", "crash", "rejected"]) { return -1 }
            return 0
        }
        let lastNegativeAt = toolObs.last(where: { outcome($0) < 0 })?.lastActivatedAt
        let lastPositiveAt = toolObs.last(where: { outcome($0) > 0 })?.lastActivatedAt
        let unresolvedRecentFailure: Double
        if let neg = lastNegativeAt {
            unresolvedRecentFailure = (lastPositiveAt.map { $0 > neg } ?? false) ? 0 : 1
        } else {
            unresolvedRecentFailure = 0
        }
        let repairEvidence: Double = {
            guard let neg = lastNegativeAt, let pos = lastPositiveAt else { return 0 }
            return pos > neg ? 1 : 0
        }()
        // Lexical resolution in THIS event, or a fresh positive tool outcome nearby.
        let lexicalResolution = text.pressure < 0   // the resolving-together signature
        a.resolutionEvidence = min(1, (lexicalResolution ? 0.7 : 0)
            + ((lastPositiveAt.map { now.timeIntervalSince($0) < 10 * 60 } ?? false) ? 0.5 : 0)
            + (event.isPositiveTerminalOutcome ? 0.6 : 0))
        // Effort: how much tool churn led up to this moment.
        a.effortEvidence = min(1, Double(toolObs.count) / 6.0)

        // -- goalRelevance ------------------------------------------------------
        let kindBase: Double
        switch event.kind {
        case .userCorrection, .toolFailed, .providerFailure: kindBase = 0.9
        case .providerVitalsShift: kindBase = 0.7
        case .workshopExecutionCompleted: kindBase = 0.8
        case .userMessageReceived: kindBase = 0.7
        case .toolSucceeded, .toolStarted: kindBase = 0.6
        case .toolCancelled: kindBase = 0.2
        case .assistantTurnCompleted: kindBase = 0.25
        case .appWake, .appSleep: kindBase = 0.1
        case .organismResolutionFelt: kindBase = 0.55
        }
        let subjectKey = "\(event.subject.type):\(event.subject.id)"
        // Exclude newly created self-evidence; reactivated older nodes still establish subject continuity.
        let isSelfEvidence: (CognitiveNode) -> Bool = { node in
            "\(node.subjectReference.type):\(node.subjectReference.id)" == subjectKey
                && now.timeIntervalSince(node.createdAt) < 1.0
        }
        let continuity = recent.contains {
            !isSelfEvidence($0)
                && "\($0.subjectReference.type):\($0.subjectReference.id)" == subjectKey
        } ? 1.0 : 0.0
        let careHit = touchedCares.isEmpty ? 0.0 : 1.0
        a.goalRelevance = (0.45 * event.importance + 0.30 * kindBase
            + 0.20 * continuity + 0.10 * careHit).clamped01()

        // -- goalCongruence -----------------------------------------------------
        let relief = (event.kind == .toolSucceeded && unresolvedRecentFailure == 0 && repairEvidence > 0) ? 1.0 : 0.0
        a.worldviewStance = touchedCares.first(where: { $0.stance != nil })?.charge(at: now).clampedSigned() ?? 0
        a.worldviewConflict = max(0, -a.worldviewStance)
        a.goalCongruence = (0.45 * outcomeSign + 0.75 * text.valence
            + 0.25 * relief - 0.25 * unresolvedRecentFailure
            + Self.appraisalWorldviewStanceCongruenceGain * a.worldviewStance).clampedSigned()

        // -- selfAgency ---------------------------------------------------------
        switch event.kind {
        case .assistantTurnCompleted: a.selfAgency = 0.7
        case .toolStarted, .toolSucceeded, .toolFailed, .workshopExecutionCompleted: a.selfAgency = 0.35
        case .toolCancelled: a.selfAgency = 0
        case .userMessageReceived, .userCorrection: a.selfAgency = -0.3
        case .providerFailure, .providerVitalsShift: a.selfAgency = -0.1
        case .appWake, .appSleep: a.selfAgency = 0
        case .organismResolutionFelt: a.selfAgency = 0.35
        }

        // -- novelty ------------------------------------------------------------
        // Similarity = recency-weighted "seen this lately" over subject key + kind.
        var similarity = 0.0
        for node in recent where !isSelfEvidence(node) {
            let sameSubject = "\(node.subjectReference.type):\(node.subjectReference.id)" == subjectKey
            let sameSession = event.sessionId != nil && node.metadata["sessionId"] == event.sessionId.map(JSONValue.string)
            guard sameSubject || sameSession else { continue }
            let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
            similarity = max(similarity, pow(0.5, age / (15 * 60)) * (sameSubject ? 1.0 : 0.6))
        }
        a.novelty = (1 - similarity).clamped01()

        // -- copingPotential ----------------------------------------------------
        let capacity = 1 - 0.6 * post.uncertainty - 0.4 * post.taskPressure   // 0…1
        a.copingPotential = ((capacity * 2 - 1) * 0.7 + repairEvidence * 0.3).clampedSigned()

        // -- relationship -------------------------------------------------------
        let isLiveChat = event.kind == .userMessageReceived || event.kind == .userCorrection
        let userRecent = lastUserPresenceAt.map { now.timeIntervalSince($0) < 30 * 60 } ?? false
        let lexicalRelational = text.warmth != 0 || precomputedWarmthBoost > 0
        a.relationshipStake = ((isLiveChat ? 0.6 : 0)
            + (lexicalRelational ? 0.3 : 0)
            + (userRecent && event.kind == .assistantTurnCompleted ? 0.1 : 0)
            + 0.2 * post.socialWarmth).clamped01()
        a.relationshipCongruence = (text.valence + 0.5 * text.warmth
            - (event.kind == .userCorrection ? 0.15 : 0)).clampedSigned()

        return a
    }

    /// R2-B: the meaning-weighted outcome base — replaces the flat ±0.25 eventBase.
    /// Routine completions (nothing resolved, no reaction) land ~0; a real fix after
    /// effort lands positive; an unresolved-failure completion can land mildly
    /// negative. Success/failure events scale by how much they MATTERED.
    func meaningWeightedOutcomeBase(for event: CognitiveEvent, appraisal a: SemanticAppraisal) -> Double {
        if event.isPositiveTerminalOutcome {
            return 0.25 * a.goalRelevance * max(0.25, a.resolutionEvidence)
        }
        if event.isNegativeTerminalOutcome {
            return -0.25 * a.goalRelevance * (0.7 + 0.3 * max(0, -a.copingPotential))
        }
        switch event.kind {
        case .assistantTurnCompleted:
            // The metronome killer: effort alone is charge, not happiness; an
            // unresolved failure weighs the completion DOWN.
            let unresolvedDrag = a.goalCongruence < 0 ? 0.08 : 0.0
            let raw = 0.10 * a.resolutionEvidence
                - 0.06 * a.effortEvidence * (1 - a.resolutionEvidence)
                - unresolvedDrag
            return min(Self.appraisalCompletionBaseCeiling, max(Self.appraisalCompletionBaseFloor, raw))
        default:
            return 0
        }
    }

    /// The semantic term of the revised valence formula.
    func semanticValenceTerm(_ a: SemanticAppraisal) -> Double {
        Self.appraisalGoalRelevanceWeight * a.goalRelevance * a.goalCongruence
            + Self.appraisalCopingWeight * a.goalRelevance * a.copingPotential
            + Self.appraisalAgencyWeight * a.selfAgency * a.goalCongruence
            + Self.appraisalRelationshipWeight * a.relationshipStake * a.relationshipCongruence
            - Self.appraisalNoveltyBadWeight * a.novelty * max(0, -a.goalCongruence)
            - Self.appraisalWorldviewConflictWeight * a.worldviewConflict
    }

    // MARK: - Cares as appraisal substrate

    /// Read matching once before the await-free event transition. The four
    /// seed cares participate in the same match as every grown live care: the
    /// care cue's law (`caresStandingOut`), so a turn touches a care only when
    /// one stands out for its words.
    func appraisalCares(in text: String) async -> [CognitiveCare] {
        let live = cares.values.filter { $0.fadedAt == nil }
        guard let cosines = await careCosines(to: text, among: live) else { return [] }
        return Self.caresStandingOut(cosines, among: live).compactMap { touched -> (CognitiveCare, Double)? in
            guard let current = cares[touched.care.id], current.fadedAt == nil,
                  current.updatedAt == touched.care.updatedAt else { return nil }
            return (current, touched.cosine)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id.uuidString < $1.0.id.uuidString }
        .map(\.0)
    }

}

extension CognitiveSubstrate {

    /// Valence sign → the organism's reaction vocabulary. Negative is the only
    /// violating read; everything else is "he did not push back".
    static func semanticReactionLabel(fromValence valence: Double) -> String {
        if valence < 0 { return OrganismSemanticExpectation.pushbackReaction }
        if valence > 0 { return OrganismSemanticExpectation.confirmedReaction }
        return OrganismSemanticExpectation.neutralReaction
    }
}

extension CognitiveSubstrate {
    /// A felt resolution matters only when its words touch a live care.
    func feltResolutionIsAtStake(_ event: CognitiveEvent, cares touchedCares: [CognitiveCare]) -> Bool {
        event.kind != .organismResolutionFelt || !touchedCares.isEmpty
    }
}

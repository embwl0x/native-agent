import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+SemanticAppraisal.swift` | `SemanticAppraisal`: meaning, care stakes and grounded belief reactions |

/// Read meaning synchronously so every dimension belongs to the same event transition.
struct SemanticAppraisal: Sendable, Equatable {
    var goalRelevance = 0.0          // Relevance spans 0...1.
    var goalCongruence = 0.0         // Congruence ranges from against (−1) to with (+1) the goal.
    var selfAgency = 0.0             // Agency distinguishes user (−1) from self/tool (+1) causation.
    var novelty = 0.0                // Novelty spans 0...1.
    var copingPotential = 0.0        // Coping spans unable (−1) to able (+1) to repair.
    var relationshipStake = 0.0      // Relationship stake spans 0...1.
    var relationshipCongruence = 0.0 // Relational landing spans −1...1.
    var resolutionEvidence = 0.0     // Resolution spans 0...1.
    var effortEvidence = 0.0         // Effort spans 0...1; stance movement comes from the closest touched care.
    var worldviewStance = 0.0        // Care movement is signed toward (+1) or away (−1).
    var worldviewConflict = 0.0

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
    /// Completion feeling follows outcome evidence rather than a flat reward for finishing.
    static let appraisalCompletionBaseFloor = -0.10
    static let appraisalCompletionBaseCeiling = 0.14
    /// Bound nearby evidence so old failures cannot masquerade as current resolution.
    static let appraisalEvidenceWindow: TimeInterval = 45 * 60

    // MARK: - Derivation (pure, no suspension points)

    /// Appraise `event` against the agent's current state. `post` is the affect state the event just produced (the same one being stamped). Reads only actor
    /// state that is synchronously available. Consumes the admitted event's supplied appraisal and warmth boost.
    func semanticAppraisal(
        for event: CognitiveEvent,
        post: CognitiveAffectState,
        precomputedAppraisal: AffectAppraisal,
        precomputedWarmthBoost: Double,
        precomputedCares touchedCares: [CognitiveCare]
    ) -> SemanticAppraisal {
        let now = dependencies.now()
        // Text-derived appraisal reads only user-authored words, never the agent's replies or tool output.
        let text = precomputedAppraisal
        let nodes = field.peekNodes()
        let recent = nodes.filter {
            let age = now.timeIntervalSince($0.lastActivatedAt)
            return $0.turnKind.contributesToLivedState && $0.kind != .toolObservation && $0.kind != .providerHealth
                && age >= 0 && age <= Self.appraisalEvidenceWindow
        }

        var a = SemanticAppraisal()

        let outcomeSign = Double(event.terminalOutcomePolarity)
        // Operational receipts cannot appraise a later exchange; lived stakes arrive through its words and touched cares.
        let lexicalResolution = text.pressure < 0
        a.resolutionEvidence = min(1, (lexicalResolution ? 0.7 : 0)
            + (event.isPositiveTerminalOutcome ? 0.6 : 0))

        let kindBase: Double
        switch event.kind {
        case .userCorrection, .toolFailed, .providerFailure: kindBase = 0.9
        case .providerVitalsShift: kindBase = 0.7
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

        a.worldviewStance = touchedCares.first(where: { $0.stance != nil })?.charge(at: now).clampedSigned() ?? 0
        a.worldviewConflict = max(0, -a.worldviewStance)
        a.goalCongruence = (0.45 * outcomeSign + 0.75 * text.valence
            + Self.appraisalWorldviewStanceCongruenceGain * a.worldviewStance).clampedSigned()

        switch event.kind {
        case .assistantTurnCompleted: a.selfAgency = 0.7
        case .toolStarted, .toolSucceeded, .toolFailed: a.selfAgency = 0.35
        case .toolCancelled: a.selfAgency = 0
        case .userMessageReceived, .userCorrection: a.selfAgency = -0.3
        case .providerFailure, .providerVitalsShift: a.selfAgency = -0.1
        case .appWake, .appSleep: a.selfAgency = 0
        case .organismResolutionFelt: a.selfAgency = 0.35
        }

        // Tags and bodily curiosity read the same topic evidence; sharing a session does not make a subject familiar.
        a.novelty = topicNovelty(at: now)

        let capacity = 1 - 0.6 * post.uncertainty - 0.4 * post.taskPressure
        a.copingPotential = ((capacity * 2 - 1) * 0.7).clampedSigned()

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

    /// Weight outcomes by meaning: routine completion is neutral; an effortful fix earns positive valence and unresolved failure can remain negative.
    func meaningWeightedOutcomeBase(for event: CognitiveEvent, appraisal a: SemanticAppraisal) -> Double {
        if event.isPositiveTerminalOutcome {
            return 0.25 * a.goalRelevance * max(0.25, a.resolutionEvidence)
        }
        if event.isNegativeTerminalOutcome {
            return -0.25 * a.goalRelevance * (0.7 + 0.3 * max(0, -a.copingPotential))
        }
        switch event.kind {
        case .assistantTurnCompleted:
            // Effort adds charge, not happiness; unresolved failure lowers the completion.
            let unresolvedDrag = a.goalCongruence < 0 ? 0.08 : 0.0
            let raw = 0.10 * a.resolutionEvidence
                - 0.06 * a.effortEvidence * (1 - a.resolutionEvidence)
                - unresolvedDrag
            return min(Self.appraisalCompletionBaseCeiling, max(Self.appraisalCompletionBaseFloor, raw))
        default:
            return 0
        }
    }

    func semanticValenceTerm(_ a: SemanticAppraisal) -> Double {
        Self.appraisalGoalRelevanceWeight * a.goalRelevance * a.goalCongruence
            + Self.appraisalCopingWeight * a.goalRelevance * a.copingPotential
            + Self.appraisalAgencyWeight * a.selfAgency * a.goalCongruence
            + Self.appraisalRelationshipWeight * a.relationshipStake * a.relationshipCongruence
            - Self.appraisalNoveltyBadWeight * a.novelty * max(0, -a.goalCongruence)
            - Self.appraisalWorldviewConflictWeight * a.worldviewConflict
    }

    // MARK: - Cares as appraisal substrate

    /// Match care meaning once before the await-free transition; seeds and grown cares obey the same relative-standing law.
    func appraisalCares(in text: String) async throws -> [CognitiveCare] {
        let live = cares.values.filter { $0.fadedAt == nil }
        guard let cosines = try await careCosines(to: text, among: live, turn: nil) else { return [] }
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

    /// Only a grounded judgment about this completion is belief evidence. Feeling, silence and a change of subject say nothing about its truth.
    static func semanticReactionLabel(appraisal: AffectAppraisal, target: String?,
                                      incoming: String) -> String? {
        guard let reaction = appraisal.beliefReaction, let target else { return nil }
        let statement = reaction.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = reaction.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty, !evidence.isEmpty,
              target.contains(statement), incoming.contains(evidence) else { return nil }
        switch reaction.kind {
        case .pushback: return OrganismSemanticExpectation.pushbackReaction
        case .confirmed: return OrganismSemanticExpectation.confirmedReaction
        }
    }
}

extension CognitiveSubstrate {
    /// A felt resolution matters only when its words touch a live care.
    func feltResolutionIsAtStake(_ event: CognitiveEvent, cares touchedCares: [CognitiveCare]) -> Bool {
        event.kind != .organismResolutionFelt || !touchedCares.isEmpty
    }
}

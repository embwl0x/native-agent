import Foundation

public struct OrganismCapabilityBelief: Sendable, Equatable, Identifiable {
    public enum EvidenceBasis: String, Sendable, Equatable {
        case cumulativeOutcomes = "cumulative_outcomes"
        case legacyBodyConfidence = "legacy_body_confidence"
    }
    public var id: String { kind.rawValue }
    public var kind: OrganismPredictionKind
    public var successLikelihood: Double
    public var uncertainty: Double
    public var evidenceCount: Int
    public var resolvedEvidenceCount: Int
    public var expiredEvidenceCount: Int
    public var freshness: Double
    public var lastEvidenceAt: Date?
    public var evidenceBasis: EvidenceBasis

    public init(
        kind: OrganismPredictionKind,
        successLikelihood: Double,
        uncertainty: Double,
        evidenceCount: Int,
        resolvedEvidenceCount: Int,
        expiredEvidenceCount: Int,
        freshness: Double,
        lastEvidenceAt: Date? = nil,
        evidenceBasis: EvidenceBasis
    ) {
        self.kind = kind
        self.successLikelihood = successLikelihood.clamped01()
        self.uncertainty = uncertainty.clamped01()
        self.evidenceCount = max(0, evidenceCount)
        self.resolvedEvidenceCount = max(0, resolvedEvidenceCount)
        self.expiredEvidenceCount = max(0, expiredEvidenceCount)
        self.freshness = freshness.clamped01()
        self.lastEvidenceAt = lastEvidenceAt
        self.evidenceBasis = evidenceBasis
    }
}

/// A calibrated self-read over the predictive body. Beta smoothing prevents a
/// single success/failure from becoming certainty; freshness is analytic and
/// the read has no prose, prompt, action, or identity authority.
public enum OrganismCapabilitySelfModel {
    public static let freshnessHalfLife: TimeInterval = 7 * 24 * 60 * 60
    /// Half-life of the outcome evidence itself, applied on the organism clock
    /// in `OrganismPersistentState.decayed(at:)`. Matched to
    /// `freshnessHalfLife` so weight and freshness fade together: a week of
    /// silence halves what the body still counts as known. The neighbouring
    /// prediction horizons (`predictionHalfLife` 6h, typed body beliefs 2-3h)
    /// govern single in-flight expectations and are far too fast for lifetime
    /// capability evidence.
    public static let evidenceHalfLife: TimeInterval = freshnessHalfLife

    public static func beliefs(
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> [OrganismCapabilityBelief] {
        OrganismPredictionKind.allCases.map { kind in
            let evidence = ledger.predictions.values.filter { $0.kind == kind }
            let resolved = evidence.filter { $0.status == .satisfied || $0.status == .violated }
            let expired = evidence.filter { $0.status == .expired }
            let cumulative = ledger.outcomeCountsByKind?[kind.rawValue]
            let bodyPrior = bodyConfidence(for: kind, in: ledger.bodyConfidence)
            // Prefer the forgotten weights over the lifetime tally: the belief
            // is about what this capability does now, not about everything it
            // ever did. `effectiveWeights(at:)` seeds from the tally for states
            // written before forgetting existed — aged to now, so an upgrade
            // cannot make stale history read fresh — and nothing is lost.
            let weights = cumulative?.effectiveWeights(at: now)
            let expiredWeight = weights?.expired ?? Double(expired.count)
            // Eight pseudo-observations preserve the pre-counter body model as
            // a bounded prior while real per-kind outcomes take over.
            let priorStrength = 8.0
            let posterior = weights.map {
                ($0.satisfied + bodyPrior * priorStrength)
                    / ($0.satisfied + $0.violated + priorStrength)
            } ?? bodyPrior
            let resolvedWeight = weights.map { $0.satisfied + $0.violated }
                ?? Double(resolved.count)
            let evidenceWeight = weights.map { $0.satisfied + $0.violated + $0.expired }
                ?? Double(evidence.count)
            let resolutionUncertainty = 1 / sqrt(resolvedWeight + 1)
            // Smoothed by the SAME prior the posterior uses. As a bare ratio
            // this penalty is scale-free, so forgetting shrinks numerator and
            // denominator together and a bad stretch could never relax however
            // long ago it was; measured against a fixed prior it decays as the
            // evidence behind it does.
            let missingEvidencePenalty = evidenceWeight <= 0
                ? 0
                : expiredWeight / (evidenceWeight + priorStrength)
            let uncertainty = max(
                cumulative == nil ? 0.5 : 0,
                max(resolutionUncertainty, missingEvidencePenalty)
            )
            let last = cumulative?.lastEvidenceAt ?? evidence.map(\.lastUpdatedAt).max()
            let freshness = last.map {
                OrganismAnalyticDecay(
                    valueAtAnchor: 1,
                    halfLife: freshnessHalfLife,
                    anchoredAt: $0
                ).value(at: now)
            } ?? 0
            return OrganismCapabilityBelief(
                kind: kind,
                successLikelihood: (posterior).clamped01(),
                uncertainty: (uncertainty).clamped01(),
                evidenceCount: Int(evidenceWeight.rounded()),
                resolvedEvidenceCount: Int(resolvedWeight.rounded()),
                expiredEvidenceCount: Int(expiredWeight.rounded()),
                freshness: (freshness).clamped01(),
                lastEvidenceAt: last,
                evidenceBasis: cumulative == nil ? .legacyBodyConfidence : .cumulativeOutcomes
            )
        }
    }

    private static func bodyConfidence(
        for kind: OrganismPredictionKind,
        in confidence: OrganismBodyConfidence
    ) -> Double {
        switch kind {
        case .toolCompletion: confidence.toolPath
        case .providerCompletion: confidence.providerPath
        case .phoneDelivery: confidence.phonePath
        case .approvalResolution: confidence.approvalPath
        case .workflowAdvance: confidence.workflowPath
        // Item 46: no body path exists for a semantic expectation; its
        // capability belief rests on the cumulative outcome counts alone.
        case .semanticExpectation: 0.5
        }
    }
}

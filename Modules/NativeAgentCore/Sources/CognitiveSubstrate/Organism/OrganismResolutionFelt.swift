import Foundation

// Round 3 Wave A2 — anticipation RESOLVES into feeling. A1 gave the body a
// sized exhale in chemistry; this pure diff read turns notable resolutions
// into events the substrate can remember with aboutness: relief ("the thing
// I was braced for landed fine") and earned disappointment ("the thing I
// counted on fell through"). Rate-bounded per path kind so retry storms
// never flood her memory. Pure: same inputs → same outputs; the caller
// (OrganismKernel.ingest) owns state.

public struct OrganismResolutionFeltEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case relief
        case disappointment
    }

    public let kind: Kind
    public let pathKind: OrganismPredictionKind
    /// The organ the resolved expectation was about ("tool:swift_build") —
    /// real aboutness for the felt node the substrate mints.
    public let sourceOrgan: String
    /// Relief: how braced the body was (0…1). Disappointment: how far above
    /// even odds the expectation sat (0…0.5).
    public let magnitude: Double
    public let occurredAt: Date
    /// Item 46 (review fix 6): PROVENANCE for a `.semanticExpectation`
    /// resolution — the session and completion turn the resolved row was minted
    /// under. Nil for every other path kind.
    ///
    /// D-2's gate 1 no longer admits the semantic label unconditionally: a felt
    /// event carrying `semanticExpectation` as its `subject.label` but no
    /// provenance could otherwise skip the aboutness gate entirely. The runtime
    /// composing the cognitive event stamps these as
    /// `OrganismSemanticExpectation.sessionMetadataKey` /`.turnMetadataKey`, and
    /// the gate requires them.
    public let semanticScope: OrganismSemanticScope?

    public init(
        kind: Kind,
        pathKind: OrganismPredictionKind,
        sourceOrgan: String,
        magnitude: Double,
        occurredAt: Date,
        semanticScope: OrganismSemanticScope? = nil
    ) {
        self.kind = kind
        self.pathKind = pathKind
        self.sourceOrgan = sourceOrgan
        self.magnitude = magnitude
        self.occurredAt = occurredAt
        self.semanticScope = pathKind == .semanticExpectation ? semanticScope : nil
    }
}

public enum OrganismResolutionFelt {
    /// A resolution only FEELS like something past these floors — mild
    /// outcomes stay chemistry-only (A1) and never mint a memory.
    static let reliefBracingFloor = 0.35
    static let disappointmentExpectationFloor = 0.6
    /// At most one felt resolution per path kind per hour.
    static let feltInterval: TimeInterval = 3600

    /// Diffs the ledger across ONE OrganismPredictiveBody.applying pass and
    /// returns the felt events plus the ledger with rate stamps applied.
    /// `before` must be the ledger as it stood when the resolving signal's
    /// bracing was measured (pre-application), so the felt magnitude matches
    /// the exhale A1 actually released.
    public static func events(
        before: OrganismPredictionLedger,
        after: OrganismPredictionLedger,
        at now: Date
    ) -> (events: [OrganismResolutionFeltEvent], stamped: OrganismPredictionLedger) {
        var stamped = after
        var out: [OrganismResolutionFeltEvent] = []
        for (id, resolved) in after.predictions {
            guard let prior = before.predictions[id], prior.status == .pending else { continue }
            // Item 5 (2026-09-02): HORIZON rows share `.semanticExpectation`'s
            // kind but not its feeling. This buffer is drained by
            // `NativeCognitionRuntime.drainFeltResolutionsIntoSubstrate`, whose
            // composer knows exactly two sentences — "the <organ> path I was
            // braced for landed fine" and its letdown — and has no third for a
            // horizon that simply passed with no answer. A horizon that landed
            // early, fell through, or went unanswered is composed by the
            // runtime's own horizon lane
            // (`NativeCognitionRuntime+Expectations.swift`), which owns all
            // three phrasings including `waiting`, and reads them from the
            // ledger rather than from this buffer. Excluding them here is what
            // keeps one moment from being announced twice, in two voices.
            guard prior.horizon == nil else { continue }
            switch resolved.status {
            case .satisfied:
                let bracing = min(
                    1,
                    OrganismProspectiveAffect.predictionBracingContribution(prior, ledger: before, at: now).bracing
                        + OrganismProspectiveAffect.violationShadow(before, at: now)
                )
                guard bracing >= reliefBracingFloor,
                      rateAllows(kind: prior.kind, in: stamped, at: now) else { continue }
                out.append(OrganismResolutionFeltEvent(
                    kind: .relief, pathKind: prior.kind,
                    sourceOrgan: prior.sourceOrgan,
                    magnitude: bracing, occurredAt: now,
                    semanticScope: prior.semanticScope
                ))
                stamp(kind: prior.kind, in: &stamped, at: now)
            case .violated:
                let expectation = 0.5 * OrganismProspectiveAffect.pathConfidence(for: prior.kind, in: before.bodyConfidence)
                    + 0.5 * prior.confidence
                guard expectation >= disappointmentExpectationFloor,
                      rateAllows(kind: prior.kind, in: stamped, at: now) else { continue }
                out.append(OrganismResolutionFeltEvent(
                    kind: .disappointment, pathKind: prior.kind,
                    sourceOrgan: prior.sourceOrgan,
                    magnitude: expectation - 0.5, occurredAt: now,
                    semanticScope: prior.semanticScope
                ))
                stamp(kind: prior.kind, in: &stamped, at: now)
            default:
                continue
            }
        }
        return (out.sorted { $0.sourceOrgan < $1.sourceOrgan }, stamped)
    }

    private static func rateAllows(
        kind: OrganismPredictionKind,
        in ledger: OrganismPredictionLedger,
        at now: Date
    ) -> Bool {
        guard let last = ledger.lastResolutionFeltAt?[kind.rawValue] else { return true }
        return now.timeIntervalSince(last) >= feltInterval
    }

    private static func stamp(
        kind: OrganismPredictionKind,
        in ledger: inout OrganismPredictionLedger,
        at now: Date
    ) {
        var stamps = ledger.lastResolutionFeltAt ?? [:]
        stamps[kind.rawValue] = now
        // Defensive prune: only real kinds may occupy the map (every add has
        // a bound — the keyspace itself).
        let valid = Set([
            OrganismPredictionKind.toolCompletion, .providerCompletion,
            .phoneDelivery, .approvalResolution, .workflowAdvance,
            .semanticExpectation,
        ].map(\.rawValue))
        ledger.lastResolutionFeltAt = stamps.filter { valid.contains($0.key) }
    }
}

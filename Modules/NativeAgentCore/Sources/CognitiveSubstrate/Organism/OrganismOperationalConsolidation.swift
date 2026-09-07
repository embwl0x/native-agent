import Foundation

public struct OrganismOperationalConsolidationReceipt: Codable, Sendable, Equatable {
    public var schema: String
    public var generatedAt: Date
    public var evidenceGeneration: String
    public var pressure: Double
    public var evidenceCount: Int
    public var predictionResidual: Double
    public var transitionSurpriseResidual: Double
    public var contradictionResidual: Double
    public var fieldChargeResidual: Double
    public var calibrationResidual: Double
    public var personalModelUpdated: Bool
    public var providerCalled: Bool
    public var promptAuthority: Bool
    public var actionAuthority: Bool

    public init(reading: OrganismResidualRepairOpportunity, generatedAt: Date) {
        self.schema = "organism-operational-consolidation.v1"
        self.generatedAt = generatedAt
        self.evidenceGeneration = reading.evidenceGeneration
        self.pressure = reading.pressure
        self.evidenceCount = reading.evidenceCount
        self.predictionResidual = reading.predictionResidual
        self.transitionSurpriseResidual = reading.transitionSurpriseResidual
        self.contradictionResidual = reading.contradictionResidual
        self.fieldChargeResidual = reading.fieldChargeResidual
        self.calibrationResidual = reading.calibrationResidual
        self.personalModelUpdated = false
        self.providerCalled = false
        self.promptAuthority = false
        self.actionAuthority = false
    }
}

public struct OrganismOperationalConsolidationResult: Sendable, Equatable {
    public var receipt: OrganismOperationalConsolidationReceipt
    public var controlState: OrganismSleepControlState
}

/// Deterministic replay acknowledgement over the exact read. It changes only
/// refractory control state: no personal model, context, memory, identity,
/// prompt, action, or provider state is updated.
public enum OrganismOperationalConsolidator {
    public static func consolidate(
        _ reading: OrganismResidualRepairOpportunity,
        controlState: OrganismSleepControlState,
        at now: Date
    ) -> OrganismOperationalConsolidationResult? {
        guard reading.lanes.first(where: { $0.lane == .operationalConsolidation })?.disposition == .ready,
              !reading.resourceInhibited,
              reading.evidenceCount > 0 else { return nil }
        var next = controlState
        next.lastOperationalConsolidationAt = now
        next.lastOperationalEvidenceGeneration = reading.evidenceGeneration
        let receipt = OrganismOperationalConsolidationReceipt(reading: reading, generatedAt: now)
        next.lastOperationalReceipt = receipt
        return OrganismOperationalConsolidationResult(
            receipt: receipt,
            controlState: next
        )
    }

    /// The identity-Dream owner calls this only after its own provider/budget/
    /// trust path accepted the work — i.e. it is committed to running a dream
    /// now. Merely becoming pressure-eligible never calls a provider and never
    /// advances the 24-hour refractory control. Since 2026-09-01 the resident
    /// owner reaches this through `OrganismKernel.claimIdentityDreamIfDue`,
    /// which makes the eligibility read and this write one atomic step.
    public static func recordingAcceptedIdentityDream(
        in state: OrganismSleepControlState,
        at date: Date
    ) -> OrganismSleepControlState {
        var next = state
        next.lastProviderDreamAt = date
        return next
    }
}

/// NORTHSTAR clause 4 (2026-09-01, sweep item 39). Sleep pressure derived from
/// real residuals now FIRES the dream instead of only describing one: the
/// identity-Dream lane's disposition is the whole judgement, and this is the
/// pure read of it. No clock, no I/O, no provider — the app-side owner stays a
/// thin hand on an organism-owned decision, and every existing gate (threshold,
/// quiet, refractory, resource inhibition) is honored by construction because
/// they already resolved into the disposition.
///
/// The one thing the lane cannot see is whether Agent is mid-turn. The 30-minute
/// quiet window makes that nearly impossible on its own (a live turn keeps
/// ingesting somatic signals, which pushes the quiet boundary out), but a dream
/// must NEVER land on top of a turn in flight, so the caller passes that in and
/// it defers rather than fires.
public enum OrganismIdentityDreamTrigger {
    public enum Decision: String, Sendable, Equatable, CaseIterable {
        /// Every gate is satisfied: the owner may run ONE dream now.
        case fire
        case belowThreshold
        case waitingForQuiet
        /// A dream already ran inside the 24-hour refractory window.
        case refractory
        case resourceInhibited
        /// Eligible, but a turn is in flight. Re-decided when the turn settles.
        case turnInFlight
    }

    public static func decide(
        opportunity: OrganismResidualRepairOpportunity,
        turnInFlight: Bool
    ) -> Decision {
        let lane = opportunity.lanes.first { $0.lane == .identityDreamProposal }
        switch lane?.disposition {
        case .some(.providerBudgetGateRequired):
            return turnInFlight ? .turnInFlight : .fire
        case .some(.waitingForQuiet):
            return .waitingForQuiet
        case .some(.refractory):
            return .refractory
        case .some(.resourceInhibited):
            return .resourceInhibited
        default:
            return .belowThreshold
        }
    }
}

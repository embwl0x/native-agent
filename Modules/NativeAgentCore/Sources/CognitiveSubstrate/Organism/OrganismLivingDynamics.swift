import Foundation
// Blueprint: | `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value` |

/// Closed-form time law used by organism tissue that should change with wall
/// time without waking on a polling cadence. The stored value remains an
/// anchor; reads derive the present value.
public struct OrganismAnalyticDecay: Sendable, Equatable {
    public var valueAtAnchor: Double
    public var equilibrium: Double
    public var halfLife: TimeInterval
    public var anchoredAt: Date

    public init(
        valueAtAnchor: Double,
        equilibrium: Double = 0,
        halfLife: TimeInterval,
        anchoredAt: Date
    ) {
        self.valueAtAnchor = Self.finite(valueAtAnchor)
        self.equilibrium = Self.finite(equilibrium)
        self.halfLife = max(0, Self.finite(halfLife))
        self.anchoredAt = anchoredAt
    }

    public func value(at date: Date) -> Double {
        guard halfLife > 0 else { return equilibrium }
        let elapsed = max(0, date.timeIntervalSince(anchoredAt))
        let factor = pow(0.5, elapsed / halfLife)
        return equilibrium + ((valueAtAnchor - equilibrium) * factor)
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

public struct OrganismSleepPressureComponents: Sendable, Equatable {
    public var predictionResidual: Double
    public var transitionSurprise: Double
    public var contradictionResidual: Double
    public var fieldChargeResidual: Double
    public var calibrationResidual: Double

    public init(
        predictionResidual: Double = 0,
        transitionSurprise: Double = 0,
        contradictionResidual: Double = 0,
        fieldChargeResidual: Double = 0,
        calibrationResidual: Double = 0
    ) {
        self.predictionResidual = Self.clamp(predictionResidual)
        self.transitionSurprise = Self.clamp(transitionSurprise)
        self.contradictionResidual = Self.clamp(contradictionResidual)
        self.fieldChargeResidual = Self.clamp(fieldChargeResidual)
        self.calibrationResidual = Self.clamp(calibrationResidual)
    }

    private static func clamp(_ value: Double) -> Double {
        (value.isFinite ? value : 0).clamped01()
    }
}

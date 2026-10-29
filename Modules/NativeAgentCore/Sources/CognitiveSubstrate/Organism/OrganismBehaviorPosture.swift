import Foundation

// Blueprint: | `OrganismBehaviorPosture.swift` | `OrganismBehaviorPosture`: typed evidence decisions, optimism thresholds and operational directives; default posture renders nothing |

public enum OrganismClaimDiscipline: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case verifyBeforeCompletion
    case receiptRequired
    case avoidIrreversible
    case currentContextFirst
}

public enum OrganismToolStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case verifyBeforeRetry
    case preferKnownPath
    case pauseForApproval
    case lightweightOnly
}

/// Diagnostics stay normal; body pressure does not budget her work.
public enum OrganismLoopBudget: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
}

public struct OrganismBehaviorPosture: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var enabled: Bool
    public var posture: String
    public var claimDiscipline: OrganismClaimDiscipline
    public var toolStrategy: OrganismToolStrategy
    public var loopBudget: OrganismLoopBudget
    public var notificationRequiresReceipt: Bool
    public var directives: [String]
    public var reviewSignals: [String]

    public init(
        generatedAt: Date,
        enabled: Bool,
        posture: String,
        claimDiscipline: OrganismClaimDiscipline = .normal,
        toolStrategy: OrganismToolStrategy = .normal,
        notificationRequiresReceipt: Bool = false,
        directives: [String] = [],
        reviewSignals: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.enabled = enabled
        self.posture = Self.clean(posture, limit: 48, fallback: enabled ? "steady" : "off")
        self.claimDiscipline = claimDiscipline
        self.toolStrategy = toolStrategy
        self.loopBudget = .normal
        self.notificationRequiresReceipt = notificationRequiresReceipt
        self.directives = Self.cleanLines(directives, limit: 180, maximumCount: 6)
        self.reviewSignals = Self.cleanLines(reviewSignals, limit: 120, maximumCount: 6)
    }

    public static func from(snapshot: OrganismSnapshot) -> OrganismBehaviorPosture? {
        guard snapshot.enabled else { return nil }
        return OrganismBehaviorPosture(
            generatedAt: snapshot.generatedAt,
            enabled: true,
            posture: postureName(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            ),
            claimDiscipline: claimDiscipline(
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            ),
            toolStrategy: toolStrategy(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            ),
            notificationRequiresReceipt: notificationRequiresReceipt(bodySchema: snapshot.bodySchema),
            directives: directives(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            )
        )
    }

    public func privateRuntimeContext() -> String {
        // Default posture renders nothing; only extra directives and reviews appear.
        var items = directives.filter { $0 != Self.defaultDirective }
        items += reviewSignals.map { "Review: \($0)." }
        guard !items.isEmpty else { return "" }
        return "Ops (follow silently): " + items.joined(separator: " ")
    }

    static let defaultDirective = "Tie completion claims to observed results, not intention."

    private static func postureName(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> String {
        if bodySchema.approvalRequiresPause {
            return "approval-bound"
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 || chemicalState.vigilance >= 0.24 {
            return "careful"
        }
        if bodySchema.notificationRequiresReceipt {
            return "delivery-aware"
        }
        if bodySchema.memoryRequiresCurrentContext {
            return "context-first"
        }
        if chemicalState.curiosity >= 0.35 || chemicalState.novelty >= 0.35 {
            return "curious"
        }
        if chemicalState.coherence >= 0.58 && chemicalState.confidence >= 0.56 {
            return "steady"
        }
        return "steady"
    }

    private static func claimDiscipline(
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> OrganismClaimDiscipline {
        if bodySchema.approvalRequiresPause {
            return .avoidIrreversible
        }
        if bodySchema.notificationRequiresReceipt {
            return .receiptRequired
        }
        if bodySchema.memoryRequiresCurrentContext {
            return .currentContextFirst
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            return .verifyBeforeCompletion
        }
        return .normal
    }

    private static func toolStrategy(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> OrganismToolStrategy {
        if bodySchema.approvalRequiresPause {
            return .pauseForApproval
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            return .verifyBeforeRetry
        }
        // Prefer a known path only while its capability evidence is fresh.
        if predictionSummary.bodyConfidence.toolPath >= 0.58,
           !bodySchema.toolPathIsUnprovenOrStale {
            return .preferKnownPath
        }
        return .normal
    }

    private static func notificationRequiresReceipt(bodySchema: BodySchema) -> Bool {
        bodySchema.notificationRequiresReceipt
    }

    private static func directives(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> [String] {
        var out: [String] = [defaultDirective]
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            out.append("After provider or tool brittleness, verify before retrying or saying the work is done.")
        }
        if bodySchema.approvalRequiresPause {
            out.append("Avoid irreversible moves until an approval path is open.")
        }
        if bodySchema.notificationRequiresReceipt {
            out.append("Do not assume a phone notification was seen without a delivery receipt.")
        }
        return out
    }


    private static func cleanLines(_ values: [String], limit: Int, maximumCount: Int) -> [String] {
        values.prefix(maximumCount).compactMap {
            let value = clean($0, limit: limit, fallback: "")
            return value.isEmpty ? nil : value
        }
    }

    private static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(limit))
    }
}

// MARK: - Lossless posture decisions

/// Only confident, current typed beliefs license optimism; this gate can only move posture toward caution.
public enum BodyBeliefOptimism {
    /// Domain metrics use the same thresholds that derive provider health.
    /// Past this the read disagrees with itself or rests on too little support.
    public static let maximumOptimisticUncertainty = 0.55
    /// Below this the newest evidence has decayed past meaning — the projector's
    /// `.stale` cutoff.
    public static let minimumOptimisticFreshness = 0.05
    /// Configuration alone (estimate 0.6) never proves exercised capability.
    public static let minimumOptimisticEstimate = 0.65

    public static func licenses(
        estimate: Double,
        uncertainty: Double,
        freshness: Double
    ) -> Bool {
        guard estimate.isFinite, uncertainty.isFinite, freshness.isFinite else { return false }
        return estimate > minimumOptimisticEstimate
            && uncertainty <= maximumOptimisticUncertainty
            && freshness >= minimumOptimisticFreshness
    }

    public static func licenses(_ metrics: BodyBeliefMetrics) -> Bool {
        licenses(
            estimate: metrics.estimate,
            uncertainty: metrics.uncertainty,
            freshness: metrics.freshness
        )
    }
}

public extension BodySchema {
    /// Typed evidence decides posture; compatibility bits apply only when absent.
    var providerPathRequiresCaution: Bool {
        guard providersAvailable else { return true }
        guard let belief = providerPathBelief else { return !providersHealthy }
        return belief.state != .healthy
    }

    /// Unavailable or unknown categories require caution; unproven or stale
    /// capability withholds optimism through `toolPathIsUnprovenOrStale`.
    var toolPathRequiresCaution: Bool {
        guard let reading = toolCapabilityReading else { return !toolHandsAvailable }
        switch reading.category {
        case .available, .configured:
            return false
        case .unavailable, .unknown:
            return true
        }
    }

    /// Withhold `preferKnownPath` without confident, current capability evidence.
    var toolPathIsUnprovenOrStale: Bool {
        guard let reading = toolCapabilityReading else { return false }
        switch reading.category {
        case .available, .configured:
            return !BodyBeliefOptimism.licenses(reading.metrics)
        case .unavailable, .unknown:
            return true
        }
    }

    var memoryRequiresCurrentContext: Bool {
        guard let reading = memoryIntegrityReading else { return !memoryHealthy }
        switch reading.category {
        case .healthy:
            return !BodyBeliefOptimism.licenses(reading.metrics)
        case .degraded, .unavailable, .unknown:
            return true
        }
    }

    var approvalRequiresPause: Bool {
        guard let reading = approvalPathReading else { return !approvalChannelsOpen }
        guard reading.category == .open else { return true }
        return !BodyBeliefOptimism.licenses(reading.metrics)
    }

    var notificationRequiresReceipt: Bool {
        guard let belief = notificationDeliveryBelief else { return !notificationPathHealthy }
        switch belief.category {
        case .unconfigured:
            // An absent transport has no delivery to acknowledge and never goes stale.
            return false
        case .deviceReceived, .displayed, .userSeen:
            // Receipts age past their 36-hour horizon; they cannot prove the next delivery.
            return !BodyBeliefOptimism.licenses(belief.metrics)
        case .configured, .transportAccepted, .failed, .unknown:
            return true
        }
    }

}

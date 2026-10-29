import Foundation
import PersistenceCore
// Blueprint: | `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |

public enum OrganismPredictiveBody {
    private static let maximumPredictions = 96

    public static func predictionID(
        kind: OrganismPredictionKind,
        sourceOrgan: String,
        correlationID: String
    ) -> String {
        "pending:\(kind.rawValue):\(OrganismToken.canonicalToken(sourceOrgan)):\(OrganismToken.canonicalToken(correlationID))"
    }

    public static func applying(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState) {
        var nextLedger = ledger
        var nextChemistry = chemicalState

        // Horizon refresh belongs to applyingHorizonRefresh; ordinary signals still expire passed horizons.
        // Resolve an outcome before expiry; other signals sweep first so starts and cancellations cannot erase a miss.
        let resolvesOwnRow: Bool
        switch signal.kind {
        case .userSpoke, .toolSucceeded, .toolFailed,
             .providerSucceeded, .providerFailed,
             .phoneDeliveryReceived, .phoneDeliveryFailed,
             .approvalResolved, .deskItemClosed, .deskItemCancelled, .deskItemBlocked:
            resolvesOwnRow = true
        default:
            resolvesOwnRow = false
        }
        if !resolvesOwnRow {
            expireOverdue(at: signal.occurredAt, ledger: &nextLedger, chemicalState: &nextChemistry)
        }

        switch signal.kind {
        case .toolStarted:
            upsertPending(.toolCompletion, signal: signal, in: &nextLedger)
        case .toolSucceeded:
            resolveOperational(.toolCompletion, satisfied: true, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .toolFailed:
            resolveOperational(.toolCompletion, satisfied: false, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .toolCancelled:
            cancel(.toolCompletion, signal: signal, ledger: &nextLedger)
        case .providerStarted:
            upsertPending(.providerCompletion, signal: signal, in: &nextLedger)
        case .providerSucceeded:
            resolveOperational(.providerCompletion, satisfied: true, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .providerFailed:
            resolveOperational(.providerCompletion, satisfied: false, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .providerCancelled:
            cancel(.providerCompletion, signal: signal, ledger: &nextLedger)
        case .phoneDeliveryStarted:
            upsertPending(.phoneDelivery, signal: signal, in: &nextLedger)
        case .phoneDeliveryReceived:
            resolveOperational(.phoneDelivery, satisfied: true, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .phoneDeliveryFailed:
            resolveOperational(.phoneDelivery, satisfied: false, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .approvalRequested:
            upsertPending(.approvalResolution, signal: signal, in: &nextLedger)
        case .approvalResolved:
            resolveOperational(.approvalResolution, satisfied: true, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemCreated:
            upsertPending(.workflowAdvance, signal: signal, in: &nextLedger)
        case .deskItemClosed:
            resolveOperational(.workflowAdvance, satisfied: true, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemCancelled:
            cancel(.workflowAdvance, signal: signal, ledger: &nextLedger)
        case .deskItemBlocked:
            resolveOperational(.workflowAdvance, satisfied: false, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .assistantSpoke:
            // Only the appraisal owner's metadata can mint an expectation.
            mintSemanticExpectation(signal: signal, in: &nextLedger)
        case .userSpoke:
            // The scoped reaction answers the completion she expected a response to.
            resolveSemanticExpectations(
                signal: signal,
                ledger: &nextLedger,
                chemicalState: &nextChemistry
            )
        case .correctionReceived, .appWake, .appSleep, .horizonRefresh,
             .providerRecovered, .iPhoneReachable, .iPhoneStale,
             .memoryCommitted, .memoryCorrected, .memoryHygieneCompleted,
             .dreamCompleted, .remIntegrated, .resourcePressureChanged:
            break
        }

        if resolvesOwnRow {
            expireOverdue(at: signal.occurredAt, ledger: &nextLedger, chemicalState: &nextChemistry)
        }

        nextLedger.peripheralUncertainty = softDecay(nextLedger.peripheralUncertainty)
        nextLedger.strategyCaution = softDecay(nextLedger.strategyCaution)
        nextLedger.lastUpdatedAt = max(
            nextLedger.lastUpdatedAt ?? .distantPast,
            signal.occurredAt
        )
        nextLedger = enforcingCapacity(nextLedger)
        return (nextLedger, nextChemistry)
    }

    private static func expireOverdue(
        at date: Date,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        for id in ledger.predictions.keys.sorted() {
            guard var prediction = ledger.predictions[id],
                  prediction.status == .pending,
                  prediction.dueAt < date else { continue }
            let isMiss = applyExpiryTransition(to: &prediction, at: date)
            ledger.predictions[id] = prediction
            ledger.expiredCount = min(ledger.expiredCount, Int.max - 1) + 1
            guard isMiss else { continue }
            recordOutcome(.expired, kind: prediction.kind, at: date, ledger: &ledger)
            // An expired miss stamps the same violation clock that prospective affect reads.
            ledger.lastViolationAt = date
            if OrganismProspectiveAffect.carriesFeeling(prediction.kind) {
                ledger.lastFeltViolationAt = max(ledger.lastFeltViolationAt ?? .distantPast, date)
            }
            applyViolationEffect(
                kind: prediction.kind,
                intensity: 0.55,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
    }

    /// Live and restored rows share expiry; only non-horizon expiry is a miss.
    /// Callers own ledger effects: the live sweep stamps violation and chemistry,
    /// while restore avoids dosing a body already decayed through the gap.
    static func applyExpiryTransition(
        to prediction: inout OrganismPrediction,
        at date: Date
    ) -> Bool {
        prediction.status = .expired
        prediction.lastUpdatedAt = date
        guard prediction.horizon == nil else { return false }
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty + 0.12)
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence - 0.10)
        return true
    }

    private static func upsertPending(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        in ledger: inout OrganismPredictionLedger
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let dueAt = signal.occurredAt.addingTimeInterval(defaultHorizon(for: kind))
        if var existing = ledger.predictions[id] {
            // Correlated source evidence can arrive late. It may still inform
            // generic physiology upstream, but it cannot reopen the prediction
            // at an older epoch or move its due horizon backward.
            // Lifecycle owners may replay the same durable edge after a
            // restart. Equality is the same observation, not fresh evidence;
            // accepting it repeatedly inflated confidence and evidenceCount.
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            if existing.status == .pending,
               signal.occurredAt == existing.lastUpdatedAt { return }
            existing.status = .pending
            existing.dueAt = dueAt
            existing.confidence = OrganismBodyConfidence.clamp(existing.confidence + 0.04 * signal.intensity)
            existing.uncertainty = OrganismBodyConfidence.clamp(existing.uncertainty + 0.04 * signal.intensity)
            existing.evidenceCount = min(existing.evidenceCount, Int.max - 1) + 1
            existing.lastUpdatedAt = signal.occurredAt
            ledger.predictions[id] = existing
        } else {
            ledger.predictions[id] = OrganismPrediction(
                id: id,
                kind: kind,
                sourceOrgan: OrganismToken.canonicalToken(signal.sourceOrgan),
                createdAt: signal.occurredAt,
                dueAt: dueAt,
                confidence: 0.56,
                uncertainty: 0.36,
                lastUpdatedAt: signal.occurredAt
            )
        }
    }

    private static func resolveOperational(
        _ kind: OrganismPredictionKind,
        satisfied: Bool,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let existing = ledger.predictions[id]
        let status: OrganismPredictionStatus = satisfied ? .satisfied : .violated
        if let existing {
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            // A replay of the same terminal edge is not new evidence. Keep
            // equal-time pending→terminal transitions valid: some lifecycle
            // owners legitimately stamp both phases from one clock sample.
            if existing.status == status,
               signal.occurredAt == existing.lastUpdatedAt { return }
        }
        settlePrediction(
            existing ?? terminalPrediction(kind, signal: signal),
            satisfied: satisfied,
            anticipated: existing?.status == .pending,
            at: signal.occurredAt,
            intensity: signal.intensity,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }

    private static func cancel(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger
    ) {
        let id = pendingID(kind: kind, signal: signal)
        guard let prediction = ledger.predictions[id], prediction.status == .pending else { return }
        guard signal.occurredAt >= prediction.lastUpdatedAt else { return }
        ledger.predictions.removeValue(forKey: id)
        ledger.lastUpdatedAt = max(ledger.lastUpdatedAt ?? .distantPast, signal.occurredAt)
    }

    private static func terminalPrediction(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal
    ) -> OrganismPrediction {
        OrganismPrediction(
            id: pendingID(kind: kind, signal: signal),
            kind: kind,
            sourceOrgan: OrganismToken.canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt,
            status: .pending,
            confidence: 0.5,
            uncertainty: 0.5,
            lastUpdatedAt: signal.occurredAt
        )
    }

    /// Applies one admitted terminal transition; synthetic rows carry no bracing.
    static func settlePrediction(
        _ prediction: OrganismPrediction,
        satisfied: Bool,
        anticipated: Bool,
        at date: Date,
        intensity: Double,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        var row = prediction
        let i = intensity
        // Measure the held breath before mutating the row.
        let bracing = satisfied && anticipated
            ? min(1, OrganismProspectiveAffect.predictionBracingContribution(
                    row, ledger: ledger, at: date
                  ).bracing + OrganismProspectiveAffect.violationShadow(ledger, at: date))
            : 0
        if satisfied {
            if row.status != .satisfied {
                ledger.satisfiedCount = min(ledger.satisfiedCount, Int.max - 1) + 1
                recordOutcome(.satisfied, kind: row.kind, at: date, ledger: &ledger)
            }
            row.status = .satisfied
            row.confidence = OrganismBodyConfidence.clamp(row.confidence + 0.18 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty - 0.16 * i)
        } else {
            if row.status != .violated {
                ledger.violatedCount = min(ledger.violatedCount, Int.max - 1) + 1
                recordOutcome(.violated, kind: row.kind, at: date, ledger: &ledger)
            }
            row.status = .violated
            row.confidence = OrganismBodyConfidence.clamp(row.confidence - 0.20 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty + 0.22 * i)
            ledger.lastViolationAt = date
            if OrganismProspectiveAffect.carriesFeeling(row.kind) {
                ledger.lastFeltViolationAt = max(ledger.lastFeltViolationAt ?? .distantPast, date)
            }
        }
        row.evidenceCount = min(row.evidenceCount, Int.max - 1) + 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        if satisfied {
            applySatisfiedEffect(
                kind: row.kind, intensity: i, bracing: bracing,
                ledger: &ledger, chemicalState: &chemicalState
            )
        } else {
            applyViolationEffect(
                kind: row.kind, intensity: i,
                ledger: &ledger, chemicalState: &chemicalState
            )
        }
    }

    /// Rows the incoming terminal signal can settle, before wall-time expiry.
    static func resolvingPredictionIDs(signal: SomaticSignal, in ledger: OrganismPredictionLedger) -> Set<String> {
        let kind: OrganismPredictionKind
        switch signal.kind {
        case .toolSucceeded, .toolFailed: kind = .toolCompletion
        case .providerSucceeded, .providerFailed: kind = .providerCompletion
        case .phoneDeliveryReceived, .phoneDeliveryFailed: kind = .phoneDelivery
        case .approvalResolved: kind = .approvalResolution
        case .deskItemClosed, .deskItemCancelled, .deskItemBlocked: kind = .workflowAdvance
        case .userSpoke:
            return Set(semanticPredictionsResolved(by: signal, in: ledger)?.ids ?? [])
        default: return []
        }
        let id = pendingID(kind: kind, signal: signal)
        guard let row = ledger.predictions[id], row.status == .pending,
              signal.occurredAt >= row.lastUpdatedAt else { return [] }
        return [id]
    }

    /// Relief releases up to 2.5 times the calm-path amount in proportion to bracing; zero bracing leaves gain at one.
    static let reliefGain = 1.5

    static func applySatisfiedEffect(
        kind: OrganismPredictionKind,
        intensity: Double,
        bracing: Double = 0,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let i = OrganismBodyConfidence.clamp(intensity)
        let release = 1 + Self.reliefGain * OrganismBodyConfidence.clamp(bracing)
        adjustBodyConfidence(kind, by: 0.08 * i, in: &ledger.bodyConfidence)
        ledger.peripheralUncertainty = lower(ledger.peripheralUncertainty, by: kind == .phoneDelivery ? 0.10 * i : 0.02 * i)
        ledger.strategyCaution = lower(ledger.strategyCaution, by: 0.08 * i * release)
        chemicalState.confidence = raise(chemicalState.confidence, by: 0.03 * i * release)
        chemicalState.vigilance = lower(chemicalState.vigilance, by: 0.04 * i * release)
        chemicalState.urgency = lower(chemicalState.urgency, by: 0.04 * i * release)
    }

    private static func applyViolationEffect(
        kind: OrganismPredictionKind,
        intensity: Double,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let i = OrganismBodyConfidence.clamp(intensity)
        adjustBodyConfidence(kind, by: -0.10 * i, in: &ledger.bodyConfidence)
        switch kind {
        case .phoneDelivery:
            ledger.peripheralUncertainty = raise(ledger.peripheralUncertainty, by: 0.12 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.015 * i)
        case .toolCompletion:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.18 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.08 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.05 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.04 * i)
        case .providerCompletion:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.12 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.10 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.04 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.05 * i)
        case .approvalResolution:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.08 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.025 * i)
            chemicalState.urgency = lower(chemicalState.urgency, by: 0.02 * i)
        case .workflowAdvance:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.14 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.05 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.04 * i)
        case .semanticExpectation:
            // Disagreement raises caution and lowers confidence without urgency.
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.16 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.06 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.05 * i)
        }
    }

    private static func adjustBodyConfidence(
        _ kind: OrganismPredictionKind,
        by amount: Double,
        in confidence: inout OrganismBodyConfidence
    ) {
        switch kind {
        case .providerCompletion:
            confidence.providerPath = OrganismBodyConfidence.clamp(confidence.providerPath + amount)
        case .toolCompletion:
            confidence.toolPath = OrganismBodyConfidence.clamp(confidence.toolPath + amount)
        case .phoneDelivery:
            confidence.phonePath = OrganismBodyConfidence.clamp(confidence.phonePath + amount)
        case .approvalResolution:
            confidence.approvalPath = OrganismBodyConfidence.clamp(confidence.approvalPath + amount)
        case .workflowAdvance:
            confidence.workflowPath = OrganismBodyConfidence.clamp(confidence.workflowPath + amount)
        case .semanticExpectation:
            // No body path by design (see the kind's doc comment). Being right
            // or wrong about how work lands is not evidence about her hands.
            break
        }
    }

    private static func enforcingCapacity(_ ledger: OrganismPredictionLedger) -> OrganismPredictionLedger {
        guard ledger.predictions.count > maximumPredictions else { return ledger }
        var next = ledger
        let keep = Set(OrganismPredictionRetention.bounded(
            Array(ledger.predictions.values), maximum: maximumPredictions
        ).map(\.id))
        next.predictions = ledger.predictions.filter { keep.contains($0.key) }
        return next
    }

    /// Live and restart/idle sweeps stamp the same cumulative outcome evidence.
    static func recordOutcome(
        _ status: OrganismPredictionStatus,
        kind: OrganismPredictionKind,
        at date: Date,
        ledger: inout OrganismPredictionLedger
    ) {
        var all = ledger.outcomeCountsByKind ?? [:]
        var count = all[kind.rawValue] ?? OrganismPredictionOutcomeCounts()
        var weights = count.effectiveWeights(at: date)
        switch status {
        case .satisfied:
            count.satisfied = min(count.satisfied, Int.max - 1) + 1
            weights.satisfied += 1
        case .violated:
            count.violated = min(count.violated, Int.max - 1) + 1
            weights.violated += 1
        case .expired:
            count.expired = min(count.expired, Int.max - 1) + 1
            weights.expired += 1
        case .pending: return
        }
        count.weights = weights
        count.lastEvidenceAt = max(count.lastEvidenceAt ?? .distantPast, date)
        all[kind.rawValue] = count
        ledger.outcomeCountsByKind = all
    }

    private static func defaultHorizon(for kind: OrganismPredictionKind) -> TimeInterval {
        switch kind {
        case .toolCompletion: return 90
        case .providerCompletion: return 45
        case .phoneDelivery: return 300
        case .approvalResolution: return 60 * 60
        case .workflowAdvance: return 10 * 60
        case .semanticExpectation: return OrganismSemanticExpectation.horizon
        }
    }

    private static func pendingID(kind: OrganismPredictionKind, signal: SomaticSignal) -> String {
        predictionID(
            kind: kind,
            sourceOrgan: signal.sourceOrgan,
            correlationID: predictionCorrelationID(signal)
        )
    }

    private static func predictionCorrelationID(_ signal: SomaticSignal) -> String {
        if case .string(let raw)? = signal.metadata["predictionCorrelationId"] {
            let clean = OrganismToken.canonicalToken(raw)
            if clean != "unknown" { return clean }
        }
        return "uncorrelated"
    }

    private static func raise(_ current: Double, by amount: Double) -> Double {
        OrganismBodyConfidence.clamp(current + amount)
    }

    private static func lower(_ current: Double, by amount: Double) -> Double {
        OrganismBodyConfidence.clamp(current - amount)
    }

    private static func softDecay(_ value: Double) -> Double {
        OrganismBodyConfidence.clamp(value * 0.98)
    }

}

/// Pending expectations precede recent terminal evidence, retained fairly
/// across capability kinds without favoring any terminal status.
enum OrganismPredictionRetention {
    static func bounded(
        _ predictions: [OrganismPrediction],
        maximum: Int
    ) -> [OrganismPrediction] {
        guard maximum > 0 else { return [] }
        // Pending horizons rank after operational expectations so calendar rows cannot evict live work.
        let allPending = predictions.filter { $0.status == .pending }
        let pending = allPending.filter { $0.horizon == nil }.sorted(by: recentFirst)
            + allPending.filter { $0.horizon != nil }.sorted(by: recentFirst)
        if pending.count >= maximum { return Array(pending.prefix(maximum)) }

        var result = pending
        var buckets = Dictionary(grouping: predictions.filter { $0.status != .pending }, by: \.kind)
            .mapValues { Array($0.sorted(by: recentFirst).reversed()) }
        let kinds = OrganismPredictionKind.allCases
        while result.count < maximum {
            var appended = false
            for kind in kinds where result.count < maximum {
                guard let prediction = buckets[kind]?.popLast() else { continue }
                result.append(prediction)
                appended = true
            }
            if !appended { break }
        }
        return result
    }

    private static func recentFirst(_ lhs: OrganismPrediction, _ rhs: OrganismPrediction) -> Bool {
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        if lhs.uncertainty != rhs.uncertainty { return lhs.uncertainty > rhs.uncertainty }
        return lhs.id < rhs.id
    }
}

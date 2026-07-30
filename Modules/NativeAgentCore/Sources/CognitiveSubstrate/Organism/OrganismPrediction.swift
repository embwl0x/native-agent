import Foundation

public enum OrganismPredictionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case toolCompletion
    case providerCompletion
    case phoneDelivery
    case approvalResolution
    case workflowAdvance
}

public enum OrganismPredictionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case satisfied
    case violated
    case expired
}

public struct OrganismBodyConfidence: Codable, Sendable, Equatable {
    public var providerPath: Double
    public var toolPath: Double
    public var phonePath: Double
    public var approvalPath: Double
    public var workflowPath: Double

    public init(
        providerPath: Double = 0.5,
        toolPath: Double = 0.5,
        phonePath: Double = 0.5,
        approvalPath: Double = 0.5,
        workflowPath: Double = 0.5
    ) {
        self.providerPath = Self.clamp(providerPath)
        self.toolPath = Self.clamp(toolPath)
        self.phonePath = Self.clamp(phonePath)
        self.approvalPath = Self.clamp(approvalPath)
        self.workflowPath = Self.clamp(workflowPath)
    }

    public static let neutral = OrganismBodyConfidence()

    static func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }
}

public struct OrganismPrediction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismPredictionKind
    public var sourceOrgan: String
    public var createdAt: Date
    public var dueAt: Date
    public var status: OrganismPredictionStatus
    public var confidence: Double
    public var uncertainty: Double
    public var evidenceCount: Int
    public var lastUpdatedAt: Date

    public init(
        id: String,
        kind: OrganismPredictionKind,
        sourceOrgan: String,
        createdAt: Date,
        dueAt: Date,
        status: OrganismPredictionStatus = .pending,
        confidence: Double = 0.5,
        uncertainty: Double = 0.5,
        evidenceCount: Int = 1,
        lastUpdatedAt: Date
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.kind = kind
        self.sourceOrgan = String(sourceOrgan.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.status = status
        self.confidence = OrganismBodyConfidence.clamp(confidence)
        self.uncertainty = OrganismBodyConfidence.clamp(uncertainty)
        self.evidenceCount = max(0, evidenceCount)
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct OrganismPredictionLimits: Sendable, Equatable {
    public var maximumPredictions: Int

    public init(maximumPredictions: Int = 96) {
        self.maximumPredictions = max(0, maximumPredictions)
    }

    public static let defaults = OrganismPredictionLimits()
}

public struct OrganismPredictionSummary: Codable, Sendable, Equatable {
    public var pendingCount: Int
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var averagePendingConfidence: Double
    public var averagePendingUncertainty: Double
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastViolationAt: Date?

    public init(
        pendingCount: Int = 0,
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        averagePendingConfidence: Double = 0,
        averagePendingUncertainty: Double = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastViolationAt: Date? = nil
    ) {
        self.pendingCount = max(0, pendingCount)
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.averagePendingConfidence = OrganismBodyConfidence.clamp(averagePendingConfidence)
        self.averagePendingUncertainty = OrganismBodyConfidence.clamp(averagePendingUncertainty)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastViolationAt = lastViolationAt
    }

    public static let empty = OrganismPredictionSummary()
}

public struct OrganismPredictionLedger: Codable, Sendable, Equatable {
    public var predictions: [String: OrganismPrediction]
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastUpdatedAt: Date?
    public var lastViolationAt: Date?
    /// Round 3 Wave A2: per-path rate stamps for FELT resolutions (relief /
    /// disappointment nodes) — at most one felt event per prediction kind per
    /// hour, so a retry storm can't flood her memory with exhales. Optional:
    /// pre-A2 organism_state.json decodes as nil (additive wire). Keys are
    /// OrganismPredictionKind rawValues — inherently capped at the 5 kinds.
    public var lastResolutionFeltAt: [String: Date]?

    public init(
        predictions: [String: OrganismPrediction] = [:],
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastUpdatedAt: Date? = nil,
        lastViolationAt: Date? = nil
    ) {
        self.predictions = predictions
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastUpdatedAt = lastUpdatedAt
        self.lastViolationAt = lastViolationAt
    }

    public static let empty = OrganismPredictionLedger()

    public func summary() -> OrganismPredictionSummary {
        let pending = predictions.values.filter { $0.status == .pending }
        let averageConfidence = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.confidence } / Double(pending.count)
        let averageUncertainty = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.uncertainty } / Double(pending.count)
        return OrganismPredictionSummary(
            pendingCount: pending.count,
            satisfiedCount: satisfiedCount,
            violatedCount: violatedCount,
            expiredCount: expiredCount,
            averagePendingConfidence: averageConfidence,
            averagePendingUncertainty: averageUncertainty,
            peripheralUncertainty: peripheralUncertainty,
            strategyCaution: strategyCaution,
            bodyConfidence: bodyConfidence,
            lastViolationAt: lastViolationAt
        )
    }
}

public enum OrganismPredictiveBody {
    public static func applying(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        limits: OrganismPredictionLimits = .defaults
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState, bodySchema: BodySchema) {
        var nextLedger = ledger
        var nextChemistry = chemicalState
        var nextBody = bodySchema

        // Ordering (reviews ccd2f13456f8 + 25de444129c7): RESOLUTION signals
        // settle their own row BEFORE expiry — a prediction resolving one
        // beat past due is exactly the outcome the body braced hardest for;
        // expiring it first stamped a violation, denied the relief, and (for
        // late failures) punished the same row twice. Every OTHER signal
        // keeps the historical expiry-first order: a repeated start must not
        // refresh its own overdue row past the sweep (the missed expectation
        // is real), and cancellation of an overdue row stays a violation-
        // stamped expiry, not a silent removal.
        let resolvesOwnRow: Bool
        switch signal.kind {
        case .toolSucceeded, .toolFailed,
             .providerSucceeded, .providerFailed,
             .phoneDeliveryReceived, .phoneDeliveryFailed,
             .approvalResolved, .deskItemClosed, .deskItemBlocked:
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
            nextBody.toolCapabilityReading = nil
            satisfy(.toolCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.toolHandsAvailable = true
        case .toolFailed:
            nextBody.toolCapabilityReading = nil
            violate(.toolCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.toolHandsAvailable = false
        case .toolCancelled:
            cancel(.toolCompletion, signal: signal, ledger: &nextLedger)
        case .providerStarted:
            nextBody.providerPathBelief = nil
            upsertPending(.providerCompletion, signal: signal, in: &nextLedger)
        case .providerSucceeded:
            nextBody.providerPathBelief = nil
            satisfy(.providerCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.providersHealthy = true
        case .providerFailed:
            nextBody.providerPathBelief = nil
            violate(.providerCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.providersHealthy = false
        case .providerCancelled:
            nextBody.providerPathBelief = nil
            cancel(.providerCompletion, signal: signal, ledger: &nextLedger)
        case .providerRecovered:
            nextBody.providerPathBelief = nil
            nextBody.providersHealthy = true
        case .iPhoneReachable:
            nextBody.peerPresenceBelief = nil
            nextBody.iPhoneReachable = true
            nextBody.notificationPathHealthy = true
        case .iPhoneStale:
            nextBody.peerPresenceBelief = nil
            nextBody.iPhoneReachable = false
            nextBody.notificationPathHealthy = false
        case .phoneDeliveryStarted:
            nextBody.notificationDeliveryBelief = nil
            upsertPending(.phoneDelivery, signal: signal, in: &nextLedger)
        case .phoneDeliveryReceived:
            nextBody.notificationDeliveryBelief = nil
            satisfy(.phoneDelivery, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.iPhoneReachable = true
            nextBody.notificationPathHealthy = true
        case .phoneDeliveryFailed:
            nextBody.notificationDeliveryBelief = nil
            violate(.phoneDelivery, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .approvalRequested:
            upsertPending(.approvalResolution, signal: signal, in: &nextLedger)
        case .approvalResolved:
            satisfy(.approvalResolution, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemCreated:
            upsertPending(.workflowAdvance, signal: signal, in: &nextLedger)
        case .deskItemClosed:
            satisfy(.workflowAdvance, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemBlocked:
            violate(.workflowAdvance, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .memoryCommitted, .memoryCorrected, .memoryHygieneCompleted:
            nextBody.memoryIntegrityReading = nil
        case .dreamCompleted, .remIntegrated:
            nextBody.dreamIntegrityReading = nil
        case .resourcePressureChanged:
            nextBody.resourcePressureReading = nil
        case .userSpoke, .assistantSpoke, .correctionReceived, .appWake, .appSleep:
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
        nextLedger = enforcingCapacity(nextLedger, limits: limits)
        return (nextLedger, nextChemistry, nextBody)
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
            prediction.status = .expired
            prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty + 0.12)
            prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence - 0.10)
            prediction.lastUpdatedAt = date
            ledger.predictions[id] = prediction
            ledger.expiredCount += 1
            // M15 (2026-07-09): an expiry damages bodyConfidence via the violation
            // effect below but never stamped lastViolationAt — so the prospective
            // shadow (modulate reads it) disagreed with the body about whether a
            // miss just happened. One clock, both readers.
            ledger.lastViolationAt = date
            applyViolationEffect(
                kind: prediction.kind,
                intensity: 0.55,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
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
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            existing.status = .pending
            existing.dueAt = dueAt
            existing.confidence = OrganismBodyConfidence.clamp(existing.confidence + 0.04 * signal.intensity)
            existing.uncertainty = OrganismBodyConfidence.clamp(existing.uncertainty + 0.04 * signal.intensity)
            existing.evidenceCount += 1
            existing.lastUpdatedAt = signal.occurredAt
            ledger.predictions[id] = existing
        } else {
            ledger.predictions[id] = OrganismPrediction(
                id: id,
                kind: kind,
                sourceOrgan: canonicalToken(signal.sourceOrgan),
                createdAt: signal.occurredAt,
                dueAt: dueAt,
                confidence: 0.56,
                uncertainty: 0.36,
                lastUpdatedAt: signal.occurredAt
            )
        }
    }

    private static func satisfy(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let existing = ledger.predictions[id]
        var prediction = existing ?? terminalPrediction(kind, signal: signal)
        guard signal.occurredAt >= prediction.lastUpdatedAt else { return }
        // Round 3 Wave A: measure how BRACED the body was for THIS outcome
        // BEFORE the resolution mutates the prediction — the same math the
        // projection used to hold the breath sizes the exhale. Only a REAL
        // pending ledger row counts (review ccd2f13456f8, Medium: the
        // synthetic terminal fallback is .pending-shaped and would mint
        // relief for an outcome nothing anticipated). Zero bracing →
        // multiplier 1 → byte-identical to the pre-relief release.
        let bracing = (existing?.status == .pending)
            ? min(1, OrganismProspectiveAffect.predictionBracingContribution(
                prediction, ledger: ledger, at: signal.occurredAt
              ).bracing + OrganismProspectiveAffect.violationShadow(ledger, at: signal.occurredAt))
            : 0
        if prediction.status != .satisfied {
            ledger.satisfiedCount += 1
        }
        prediction.status = .satisfied
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence + 0.18 * signal.intensity)
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty - 0.16 * signal.intensity)
        prediction.evidenceCount += 1
        prediction.lastUpdatedAt = signal.occurredAt
        ledger.predictions[prediction.id] = prediction
        applySatisfiedEffect(
            kind: kind,
            intensity: signal.intensity,
            bracing: bracing,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }

    private static func violate(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        var prediction = ledger.predictions[id] ?? terminalPrediction(kind, signal: signal)
        guard signal.occurredAt >= prediction.lastUpdatedAt else { return }
        if prediction.status != .violated {
            ledger.violatedCount += 1
        }
        prediction.status = .violated
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence - 0.20 * signal.intensity)
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty + 0.22 * signal.intensity)
        prediction.evidenceCount += 1
        prediction.lastUpdatedAt = signal.occurredAt
        ledger.predictions[prediction.id] = prediction
        ledger.lastViolationAt = signal.occurredAt
        applyViolationEffect(
            kind: kind,
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
            id: "terminal:\(kind.rawValue):\(canonicalToken(signal.sourceOrgan)):\(Int(signal.occurredAt.timeIntervalSince1970))",
            kind: kind,
            sourceOrgan: canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt,
            status: .pending,
            confidence: 0.5,
            uncertainty: 0.5,
            lastUpdatedAt: signal.occurredAt
        )
    }

    /// Relief gain: a satisfied outcome the body was fully braced for
    /// releases up to 2.5× the calm-path amount — the exhale is sized to the
    /// held breath (round 3 Wave A; bracing 0 → multiplier exactly 1).
    static let reliefGain = 1.5

    private static func applySatisfiedEffect(
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
        }
    }

    private static func enforcingCapacity(
        _ ledger: OrganismPredictionLedger,
        limits: OrganismPredictionLimits
    ) -> OrganismPredictionLedger {
        guard ledger.predictions.count > limits.maximumPredictions else { return ledger }
        var next = ledger
        let keep = Set(ledger.predictions.values.sorted(by: predictionSort).prefix(limits.maximumPredictions).map(\.id))
        next.predictions = ledger.predictions.filter { keep.contains($0.key) }
        return next
    }

    private static func predictionSort(_ lhs: OrganismPrediction, _ rhs: OrganismPrediction) -> Bool {
        if lhs.status != rhs.status {
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        if lhs.uncertainty != rhs.uncertainty { return lhs.uncertainty > rhs.uncertainty }
        return lhs.id < rhs.id
    }

    private static func statusRank(_ status: OrganismPredictionStatus) -> Int {
        switch status {
        case .pending: return 0
        case .violated: return 1
        case .expired: return 2
        case .satisfied: return 3
        }
    }

    private static func defaultHorizon(for kind: OrganismPredictionKind) -> TimeInterval {
        switch kind {
        case .toolCompletion: return 90
        case .providerCompletion: return 45
        case .phoneDelivery: return 300
        case .approvalResolution: return 60 * 60
        case .workflowAdvance: return 10 * 60
        }
    }

    private static func pendingID(kind: OrganismPredictionKind, signal: SomaticSignal) -> String {
        let correlation = predictionCorrelationID(signal)
        return "pending:\(kind.rawValue):\(canonicalToken(signal.sourceOrgan)):\(correlation)"
    }

    private static func predictionCorrelationID(_ signal: SomaticSignal) -> String {
        if case .string(let raw)? = signal.metadata["predictionCorrelationId"] {
            let clean = canonicalToken(raw)
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

    private static func canonicalToken(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 48 { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

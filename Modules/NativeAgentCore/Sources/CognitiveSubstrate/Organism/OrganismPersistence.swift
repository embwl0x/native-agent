import Foundation

// Blueprint: | `OrganismPersistence.swift` | `OrganismPersistentState`: checked identity, body continuity and restore decay |

public struct OrganismPersistentState: Codable, Sendable, Equatable {
    static let maximumDecayHours: Double = 72
    private static let maximumPersistedNodes = 96
    private static let maximumPersistedEdges = 192
    private static let maximumPersistedPredictions = 96

    public var schemaVersion: Int
    public var savedAt: Date
    public var chemicalState: ChemicalState
    public var bodySchema: BodySchema
    public var field: OrganismField
    public var predictionLedger: OrganismPredictionLedger
    public var dreamRepairState: OrganismDreamRepairState
    public var signalCount: Int
    public var lastSignalAt: Date?
    /// The encounter window persists with chemistry so relaunch cannot dose the same exchange twice.
    public var caringEncounter: OrganismCaringEvent.Encounter
    /// Reset and Clear persist the bumped forgetting epoch with empty chemistry so late moments from the previous epoch remain refused; absent epoch carries
    /// zero.
    public var epoch: UInt64
    /// The fold seq of the last lived moment the body lived (its whole share: dose, reaction and correction cause, in one `OrganismKernel.foldTurn`). Saved in
    /// the same atomic file write as the chemistry it describes.
    public var lived: UInt64
    /// Dream claims persist with effects; a missing claim leaves completion owed.
    public var dreamCompletions: Set<UUID>?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt, chemicalState, bodySchema, field
        case predictionLedger, dreamRepairState, signalCount, lastSignalAt
        case caringEncounter, epoch, lived, dreamCompletions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "Only the current organism state schema is supported")
        }
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        chemicalState = try container.decode(ChemicalState.self, forKey: .chemicalState)
        bodySchema = try container.decode(BodySchema.self, forKey: .bodySchema)
        field = try container.decode(OrganismField.self, forKey: .field)
        predictionLedger = try container.decode(OrganismPredictionLedger.self, forKey: .predictionLedger)
        dreamRepairState = try container.decode(OrganismDreamRepairState.self, forKey: .dreamRepairState)
        signalCount = try container.decode(Int.self, forKey: .signalCount)
        lastSignalAt = try container.decodeIfPresent(Date.self, forKey: .lastSignalAt)
        caringEncounter = try container.decode(OrganismCaringEvent.Encounter.self, forKey: .caringEncounter)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        lived = try container.decode(UInt64.self, forKey: .lived)
        dreamCompletions = try container.decodeIfPresent(Set<UUID>.self, forKey: .dreamCompletions)

        // Decay rebuilds these dictionaries by embedded ID. Validate before restoration so inconsistent JSON reaches the restore-failed handler instead of
        // trapping on duplicate keys and crashing every launch.
        func requireMatchingIDs<Value>(
            _ values: [String: Value], id: KeyPath<Value, String>, key: CodingKeys
        ) throws {
            guard values.allSatisfy({ $0.key == $0.value[keyPath: id] }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "Organism dictionary keys must match embedded IDs"
                )
            }
        }
        try requireMatchingIDs(field.nodes, id: \.id, key: .field)
        try requireMatchingIDs(field.edges, id: \.id, key: .field)
        try requireMatchingIDs(predictionLedger.predictions, id: \.id, key: .predictionLedger)
    }

    public init(
        schemaVersion: Int = 1,
        savedAt: Date,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral,
        field: OrganismField = .empty,
        predictionLedger: OrganismPredictionLedger = .empty,
        dreamRepairState: OrganismDreamRepairState = .empty,
        signalCount: Int = 0,
        lastSignalAt: Date? = nil,
        caringEncounter: OrganismCaringEvent.Encounter = .empty,
        epoch: UInt64 = 0,
        lived: UInt64 = 0,
        dreamCompletions: Set<UUID>? = nil
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.savedAt = savedAt
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
        self.field = field
        self.predictionLedger = predictionLedger
        self.dreamRepairState = dreamRepairState
        self.signalCount = max(0, signalCount)
        self.lastSignalAt = lastSignalAt
        self.caringEncounter = caringEncounter
        self.epoch = epoch
        self.lived = lived
        self.dreamCompletions = dreamCompletions
    }

    public func decayed(
        at now: Date,
        settleBodySchema: Bool = true,
        fatigueDecayLimit: TimeInterval = .infinity,
        deferringPredictionExpiry deferredIDs: Set<String> = []
    ) -> OrganismPersistentState {
        let elapsedHours = max(0, now.timeIntervalSince(savedAt) / 3_600)
        guard elapsedHours > 0 else { return self }
        let boundedHours = min(elapsedHours, Self.maximumDecayHours)

        var next = self
        next.savedAt = now
        // Tenderness and capability evidence spend the full gap; fatigue is capped only on cold restore.
        next.chemicalState = Self.decayedChemistry(
            chemicalState, hours: boundedHours, tendernessHours: elapsedHours,
            fatigueElapsed: min(now.timeIntervalSince(savedAt), fatigueDecayLimit))
        next.bodySchema = settleBodySchema ? settledBodySchema(bodySchema) : bodySchema
        next.field = decayedField(field, hours: boundedHours)
        next.predictionLedger = decayedPredictions(
            predictionLedger, now: now, hours: boundedHours,
            evidenceHours: elapsedHours, deferredIDs: deferredIDs)
        next.signalCount = max(0, signalCount)
        return next
    }

    static func decayedChemistry(
        _ state: ChemicalState, hours: Double, tendernessHours: Double, fatigueElapsed: TimeInterval
    ) -> ChemicalState {
        let quick = pow(0.78, hours)
        let slow = pow(0.92, hours)
        let neutral = ChemicalState.neutral
        func towardZero(_ value: Double, factor: Double = quick) -> Double {
            (value * factor).clamped01()
        }
        func towardNeutral(_ value: Double, neutral neutralValue: Double, factor: Double = slow) -> Double {
            (neutralValue + ((value - neutralValue) * factor)).clamped01()
        }
        return ChemicalState(
            warmth: towardZero(state.warmth, factor: slow),
            vigilance: towardZero(state.vigilance),
            curiosity: towardZero(state.curiosity, factor: slow),
            fatigue: OrganismChemistry.relaxedFatigue(state.fatigue, elapsed: fatigueElapsed),
            coherence: towardNeutral(state.coherence, neutral: neutral.coherence),
            agency: towardZero(state.agency, factor: slow),
            // Tenderness decays only here over uncapped wall time with a three-day half-life, independently of signal count.
            tenderness: towardZero(
                state.tenderness,
                factor: pow(0.5, tendernessHours / (OrganismChemistry.tendernessHalfLife / 3_600))
            ),
            confidence: towardNeutral(state.confidence, neutral: neutral.confidence),
            novelty: towardZero(state.novelty),
            urgency: towardZero(state.urgency)
        )
    }

    private func settledBodySchema(_ body: BodySchema) -> BodySchema {
        var next = body
        next.resourcePressure = .nominal
        return next
    }

    private func decayedField(
        _ field: OrganismField,
        hours: Double
    ) -> OrganismField {
        let activationFactor = pow(0.82, hours)
        let chargeFactor = pow(0.90, hours)
        let eligibilityFactor = pow(0.65, hours)
        var next = field
        next.nodes = field.nodes.mapValues { node in
            var copy = node
            copy.activation = OrganismNode.clamp01(copy.activation * activationFactor)
            copy.charge = OrganismNode.clamp01(copy.charge * chargeFactor)
            return copy
        }
        next.edges = field.edges.mapValues { edge in
            var copy = edge
            copy.eligibility = OrganismNode.clamp01(copy.eligibility * eligibilityFactor)
            copy.uncertainty = OrganismNode.clamp01(copy.uncertainty + (0.01 * min(hours, 12)))
            return copy
        }
        next.nodes = Dictionary(next.nodes.values
            .sorted {
                if $0.activation != $1.activation { return $0.activation > $1.activation }
                if $0.charge != $1.charge { return $0.charge > $1.charge }
                return $0.id < $1.id
            }
            .prefix(Self.maximumPersistedNodes)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keptNodeIDs = Set(next.nodes.keys)
        next.edges = Dictionary(next.edges.values
            .filter { keptNodeIDs.contains($0.sourceID) && keptNodeIDs.contains($0.targetID) }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                if $0.eligibility != $1.eligibility { return $0.eligibility > $1.eligibility }
                return $0.id < $1.id
            }
            .prefix(Self.maximumPersistedEdges)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return next
    }

    private func decayedPredictions(
        _ ledger: OrganismPredictionLedger,
        now: Date,
        hours: Double,
        evidenceHours: Double,
        deferredIDs: Set<String>
    ) -> OrganismPredictionLedger {
        var next = ledger
        next.peripheralUncertainty = OrganismBodyConfidence.clamp(next.peripheralUncertainty * pow(0.84, hours))
        next.strategyCaution = OrganismBodyConfidence.clamp(next.strategyCaution * pow(0.82, hours))
        var expiredKinds: [OrganismPredictionKind] = []
        var expiredHorizons = 0
        let decayed = next.predictions.values.map { prediction -> OrganismPrediction in
                var copy = prediction
                if copy.status == .pending && copy.dueAt < now && !deferredIDs.contains(copy.id) {
                    // Share live expiry transitions; a passed horizon means waiting, never an incorrect prediction.
                    if OrganismPredictiveBody.applyExpiryTransition(to: &copy, at: now) {
                        expiredKinds.append(copy.kind)
                    } else {
                        expiredHorizons += 1
                    }
                    // Do not decay a freshly stamped expiry again: its evidence is dated now and the elapsed window ends now.
                    return copy
                }
                copy.uncertainty = OrganismBodyConfidence.clamp(copy.uncertainty * pow(0.94, hours))
                return copy
            }
        // Count an expiry only when its row turns terminal, using the same live-sweep rule. Decay prior evidence before adding this newly observed outcome.
        next.outcomeCountsByKind = forgottenOutcomeCounts(next.outcomeCountsByKind, at: now, hours: evidenceHours)
        next.expiredCount = min(next.expiredCount, Int.max - expiredHorizons) + expiredHorizons
        for kind in expiredKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            next.expiredCount = min(next.expiredCount, Int.max - 1) + 1
            OrganismPredictiveBody.recordOutcome(.expired, kind: kind, at: now, ledger: &next)
        }
        next.predictions = Dictionary(OrganismPredictionRetention
            .bounded(decayed, maximum: Self.maximumPersistedPredictions)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        next.lastUpdatedAt = now
        return next
    }

    /// Decay fractional outcome evidence on the capability read's seven-day freshness clock; lifetime integer receipts remain unchanged so old certainty can
    /// relax.
    private func forgottenOutcomeCounts(
        _ counts: [String: OrganismPredictionOutcomeCounts],
        at now: Date,
        hours: Double
    ) -> [String: OrganismPredictionOutcomeCounts] {
        let halfLifeHours = OrganismCapabilitySelfModel.evidenceHalfLife / 3_600
        guard hours > 0, halfLifeHours > 0 else { return counts }
        let factor = pow(0.5, hours / halfLifeHours)
        return counts.mapValues { count in
            var next = count
            let weights = count.weights
            next.weights = OrganismPredictionOutcomeWeights(
                satisfied: weights.satisfied * factor,
                violated: weights.violated * factor,
                expired: weights.expired * factor
            )
            return next
        }
    }
}

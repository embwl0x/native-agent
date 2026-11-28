import Foundation
import PersistenceCore
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `foldTurn` (the body's whole share of one lived moment, with its watermark) |

public struct OrganismDependencies: Sendable {
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    /// Bounded immutable projection of pending tool expectations. The kernel still owns the prediction ledger; readers receive no mutation handle.
    public var predictedToolGroupsSink: @Sendable (Set<String>) -> Void
    let repair: @Sendable (OrganismDreamRepair.Reading, Turn?) async throws -> OrganismDreamRepair.Plan

    package init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        predictedToolGroupsSink: @escaping @Sendable (Set<String>) -> Void = { _ in },
        repair: @escaping @Sendable (OrganismDreamRepair.Reading, Turn?) async throws -> OrganismDreamRepair.Plan
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.predictedToolGroupsSink = predictedToolGroupsSink
        self.repair = repair
    }
}

public actor OrganismKernel {
    private var mutationRevision: UInt64 = 0
    private var configuration: OrganismConfiguration { didSet { mutationRevision &+= 1 } }
    private let dependencies: OrganismDependencies
    private var body: OrganismPersistentState { didSet { mutationRevision &+= 1 } }
    /// Felt resolutions awaiting the runtime's drain, capped by dropping the oldest.
    private static let pendingResolutionFeltCap = 8
    private var pendingResolutionFelt: [OrganismResolutionFeltEvent] = [] { didSet { mutationRevision &+= 1 } }
    /// When the canonical relational crossing last integrated tenderness. In-memory: a gap the process did not observe is missing evidence, so a restart
    /// resumes integrating from the next crossing rather than claiming the whole downtime as sustained warmth.
    private var tendernessAnchorAt: Date? { didSet { mutationRevision &+= 1 } }
    /// Track capped wakefulness separately from work fatigue. Process downtime proves neither sleep nor wakefulness, so only observed elapsed time accrues.
    private var wakefulnessFatigue: Double = 0 { didSet { mutationRevision &+= 1 } }
    private static let minimumRuntimeDecayInterval: TimeInterval = 1

    public init(
        configuration: OrganismConfiguration = .disabled,
        dependencies: OrganismDependencies,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral,
        field: OrganismField = .empty,
        predictionLedger: OrganismPredictionLedger = .empty,
        dreamRepairState: OrganismDreamRepairState = .empty
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.body = OrganismPersistentState(
            savedAt: dependencies.now(), chemicalState: chemicalState,
            bodySchema: bodySchema, field: field, predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState)
    }

    public func configure(_ configuration: OrganismConfiguration) async {
        let now = dependencies.now()
        // Settle owed wall time without moving the anchor backward or spending a forward-settled interval twice.
        settleElapsedTime(at: now)
        self.configuration = configuration
        body.savedAt = max(body.savedAt, now)
        publishPredictedToolGroups()
    }

    /// The person's reaction to the agent's last completion settles the expectation it answers (part of `foldTurn`).
    private func liveAfterTurnReaction(_ signal: SomaticSignal, correctionConfidence: Double) {
        guard signal.metadata[OrganismSemanticExpectation.reactionMetadataKey] != nil else { return }
        let before = body.predictionLedger
        var next = body
        OrganismPredictiveBody.resolveSemanticExpectations(
            signal: signal, ledger: &next.predictionLedger, chemicalState: &next.chemicalState,
            correctionConfidence: correctionConfidence)
        let felt = OrganismResolutionFelt.events(before: before, after: next.predictionLedger, at: dependencies.now())
        next.predictionLedger = felt.stamped
        body = next
        pendingResolutionFelt.append(contentsOf: felt.events)
        if pendingResolutionFelt.count > Self.pendingResolutionFeltCap {
            pendingResolutionFelt.removeFirst(pendingResolutionFelt.count - Self.pendingResolutionFeltCap)
        }
    }

    /// Infrastructure signals may update health, predictions and field while feelings follow time alone.
    public func ingest(_ signal: SomaticSignal, movesFeelings: Bool = true, parent: Turn? = nil) async throws {
        guard configuration.enabled else { return }
        if signal.kind == .dreamCompleted, body.dreamCompletions?.contains(signal.id) == true { return }
        let ingestedAt = dependencies.now()
        let bounded = SomaticSignal(
            id: signal.id,
            kind: signal.kind,
            sourceOrgan: signal.sourceOrgan,
            occurredAt: signal.occurredAt,
            intensity: signal.intensity,
            valence: signal.valence,
            arousal: signal.arousal,
            metadata: signal.metadata,
            bounds: configuration.metadataBounds
        )
        // Horizon refresh updates horizons without recording traffic or consuming quiet time.
        if bounded.kind == .horizonRefresh {
            let refreshed = OrganismPredictiveBody.applyingHorizonRefresh(
                signal: bounded,
                to: body.predictionLedger,
                chemicalState: body.chemicalState,
                at: ingestedAt
            )
            body.predictionLedger = refreshed.ledger
            body.chemicalState = refreshed.chemicalState
            return
        }
        settleElapsedTime(at: ingestedAt, deferringPredictionExpiry:
            OrganismPredictiveBody.resolvingPredictionIDs(signal: bounded, in: body.predictionLedger))
        // Signal density uses ingest time; a nil first gap receives the per-signal share without claiming elapsed time.
        func derived() -> (updated: (chemicalState: ChemicalState, bodySchema: BodySchema), ledgerBefore: OrganismPredictionLedger,
                           predicted: (ledger: OrganismPredictionLedger, chemicalState: ChemicalState), field: OrganismField) {
            let updated = OrganismChemistry.applying(
                signal: bounded,
                to: body.chemicalState,
                bodySchema: body.bodySchema,
                elapsedSinceLastSignal: body.lastSignalAt.map { max(0, ingestedAt.timeIntervalSince($0)) }
            )
            let predicted = OrganismPredictiveBody.applying(
                signal: bounded,
                to: body.predictionLedger,
                chemicalState: updated.chemicalState
            )
            return (updated, body.predictionLedger, predicted, OrganismPlasticity.applying(
                signal: bounded, chemicalState: predicted.chemicalState, bodySchema: updated.bodySchema, to: body.field
            ))
        }
        var (updated, ledgerBefore, predicted, field) = derived()
        var repaired: OrganismDreamRepair.Plan?
        if bounded.kind == .dreamCompleted || bounded.kind == .remIntegrated {
            while true {
                let plan = try await dependencies.repair(.init(field: field), parent)
                try Task.checkCancellation()
                if signal.kind == .dreamCompleted, body.dreamCompletions?.contains(signal.id) == true { return }
                // Time passing only fades the field; a decision is stale when the field was written.
                let decidedOn = field.mutationGeneration
                (updated, ledgerBefore, predicted, field) = derived()
                if field.mutationGeneration == decidedOn { repaired = plan; break }
            }
        }
        // Notable resolutions carry aboutness into the substrate through a rate-stamped ledger diff and a bounded drain buffer.
        let felt = OrganismResolutionFelt.events(
            before: ledgerBefore,
            after: predicted.ledger,
            at: ingestedAt
        )
        body.predictionLedger = felt.stamped
        pendingResolutionFelt.append(contentsOf: felt.events)
        if pendingResolutionFelt.count > Self.pendingResolutionFeltCap {
            pendingResolutionFelt.removeFirst(pendingResolutionFelt.count - Self.pendingResolutionFeltCap)
        }
        if movesFeelings { body.chemicalState = predicted.chemicalState }
        body.bodySchema = updated.bodySchema
        if let repaired {
            OrganismDreamRepair.record(repaired, into: &body, at: bounded.occurredAt, signal: bounded, makeUUID: dependencies.makeUUID)
            // Dream completion resets the separately held wakefulness share as well as reducing total fatigue.
            wakefulnessFatigue = 0
            if bounded.kind == .dreamCompleted {
                if body.dreamCompletions == nil { body.dreamCompletions = [] }
                body.dreamCompletions?.insert(bounded.id)
            }
        } else {
            body.field = field
        }
        body.signalCount = min(body.signalCount, Int.max - 1) + 1
        // Quiet physiology follows when the signal reached this organism, not an untrusted/delayed source timestamp. The anchor is monotonic so an out-of-order
        // event can never make repair run early.
        body.lastSignalAt = max(body.lastSignalAt ?? .distantPast, ingestedAt)
        publishPredictedToolGroups()
    }

    public func refreshBodySchema(
        _ read: OrganismBodyRead,
        canonicalAffect: OrganismLifeReading? = nil
    ) async {
        applyBodySchema(
            read,
            canonicalAffect: canonicalAffect,
            at: dependencies.now()
        )
    }

    /// Apply the body sample and produce the turn's fixed-time organism value in one actor admission. Cognition's canonical warmth and pressure cross together;
    /// the returned read remains mutation-free and advisory.
    public func refreshBodySchemaAndFrozenRead(
        _ read: OrganismBodyRead,
        canonicalAffect: OrganismLifeReading? = nil,
        fixedAt: Date
    ) -> OrganismFrozenRead {
        applyBodySchema(
            read,
            canonicalAffect: canonicalAffect,
            at: fixedAt
        )
        return frozenRead(at: fixedAt)
    }

    private func applyBodySchema(
        _ read: OrganismBodyRead,
        canonicalAffect: OrganismLifeReading?,
        at observedAt: Date
    ) {
        guard configuration.enabled else { return }
        settleElapsedTime(at: observedAt)
        body.bodySchema = OrganismBodySchemaSampler.bodySchema(
            from: read,
            previous: body.bodySchema,
            now: observedAt
        )
        if let canonicalAffect {
            let affect = canonicalAffect.affect
            body.chemicalState.warmth = affect.socialWarmth.clampedSigned()
            body.chemicalState.urgency = affect.taskPressure.clamped01()
            // A refresh sustains current stakes without erasing lived outcomes or dosing again for another read.
            body.chemicalState.vigilance = max(
                body.chemicalState.vigilance, max(affect.uncertainty, canonicalAffect.careTension)
            ).clamped01()
            body.chemicalState.novelty = canonicalAffect.novelty
            body.chemicalState.curiosity = canonicalAffect.novelty
            body.chemicalState.coherence = (
                ChemicalState.neutral.coherence + 0.15 * canonicalAffect.careValence - 0.25 * affect.uncertainty
            ).clamped01()
            body.bodySchema.handPain = canonicalAffect.handPain
            // Elapsed since the last CROSSING, not since the last read: an Observatory poll at the same instant integrates exactly nothing.
            body.chemicalState.tenderness = OrganismChemistry.tenderness(
                body.chemicalState.tenderness,
                underCanonicalWarmth: body.chemicalState.warmth,
                elapsed: tendernessAnchorAt.map {
                    max(0, observedAt.timeIntervalSince($0))
                } ?? 0
            )
            tendernessAnchorAt = observedAt
        }
    }

    public func projection() async -> OrganismReadout {
        guard configuration.enabled else {
            return OrganismReadout(generatedAt: dependencies.now())
        }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        return projection(chemicalState: body.chemicalState, ledger: body.predictionLedger, bodySchema: body.bodySchema, at: now)
    }

    /// Anticipation and the clock color presentation without changing stored chemistry.
    private func projection(
        chemicalState: ChemicalState,
        ledger: OrganismPredictionLedger,
        bodySchema: BodySchema,
        at now: Date
    ) -> OrganismReadout {
        let anticipated = OrganismProspectiveAffect.modulate(
            chemicalState,
            ledger: ledger,
            at: now
        )
        let daily = OrganismCircadian.modulate(
            anticipated.state,
            at: now,
            clock: configuration.diurnalClock
        )
        return OrganismChemistry.projection(
            at: now,
            chemicalState: daily.state,
            bodySchema: bodySchema,
            diurnal: daily.read,
            tenderNamed: body.caringEncounter.lastCaringTurnAt.map {
                (0..<OrganismChemistry.tenderNamedWindow).contains(now.timeIntervalSince($0))
            } ?? false,
            prospect: anticipated.prospect
        )
    }

    /// The runtime pushes shared quiet-hour and clock changes before reads; the kernel owns no preference file or polling loop.
    public func configureDiurnalClock(_ clock: OrganismDiurnalClock?) {
        configuration.diurnalClock = clock
    }

    /// Read delivery outcomes from this live ledger; decoding its persisted snapshot would bypass newer resident evidence.
    public func latestPrediction(ofKind kind: OrganismPredictionKind, includingPeerWaits: Bool = true) -> OrganismPrediction? {
        guard configuration.enabled else { return nil }
        return body.predictionLedger.predictions.values
            .filter { $0.kind == kind && (includingPeerWaits || $0.horizon?.peerJobID == nil) }
            .max { lhs, rhs in
                if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                    return lhs.lastUpdatedAt < rhs.lastUpdatedAt
                }
                return lhs.id < rhs.id
            }
    }

    public func prediction(
        ofKind kind: OrganismPredictionKind,
        sourceOrgan: String,
        correlationID: String
    ) -> OrganismPrediction? {
        guard configuration.enabled else { return nil }
        let id = OrganismPredictiveBody.predictionID(
            kind: kind,
            sourceOrgan: sourceOrgan,
            correlationID: correlationID
        )
        return body.predictionLedger.predictions[id]
    }

    /// Pure deadline read for event-driven repair. No timer is owned by the kernel and no state is changed beyond ordinary analytic settlement.
    public func residualRepairOpportunity() async -> OrganismResidualRepairOpportunity {
        guard configuration.enabled else { return .empty(at: dependencies.now()) }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        return currentResidualRepairOpportunity(at: now)
    }

    @discardableResult
    public func runResidualRepairIfDue(satisfyWait: Bool = false, parent: Turn? = nil,
        isAdmitted: @Sendable () async -> Bool) async throws -> Bool {
        guard configuration.enabled else { return false }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let opportunity = currentResidualRepairOpportunity(at: now, satisfyWait: satisfyWait)
        guard opportunity.ready else { return false }
        var plan: OrganismDreamRepair.Plan
        while true {
            let decidedOn = body.field
            plan = try await dependencies.repair(.init(field: decidedOn, opportunity: opportunity), parent)
            try Task.checkCancellation()
            guard await isAdmitted() else {
                throw PartCallError(code: "field_changed", message: "Residual repair's admission changed while its part was deciding.")
            }
            if body.field.mutationGeneration == decidedOn.mutationGeneration { break }
        }
        guard plan.field != body.field else { return false }
        OrganismDreamRepair.record(plan, into: &body, at: now,
            residualEvidenceCount: opportunity.evidenceCount, makeUUID: dependencies.makeUUID)
        return true
    }

    /// Drains felt resolutions (relief / disappointment) minted since the last drain. The caller (NativeCognitionRuntime) turns each into a substrate event
    /// with the resolved organ as aboutness.
    public func drainResolutionFelt() -> [OrganismResolutionFeltEvent] {
        let drained = pendingResolutionFelt
        pendingResolutionFelt.removeAll()
        return drained
    }

    public func snapshot() async -> OrganismSnapshot {
        let now = dependencies.now()
        if configuration.enabled {
            settleElapsedTime(at: now)
        }
        return renderRead(from: body, at: now).snapshot
    }

    /// Project from a copy at one time so posture reads cannot settle or rewrite the live kernel.
    public func frozenRead(at fixedAt: Date) -> OrganismFrozenRead {
        let raw = body
        let frozen = configuration.enabled
            ? raw.decayed(at: fixedAt, settleBodySchema: false)
            : raw
        return renderRead(from: frozen, at: fixedAt)
    }

    /// The snapshot retains raw chemistry; its body line uses projected chemistry.
    private func renderRead(from state: OrganismPersistentState, at fixedAt: Date) -> OrganismFrozenRead {
        let enabled = configuration.enabled
        let projection = enabled
            ? self.projection(chemicalState: state.chemicalState, ledger: state.predictionLedger, bodySchema: state.bodySchema, at: fixedAt)
            : OrganismReadout(generatedAt: fixedAt)
        let snapshot = OrganismSnapshot(
            generatedAt: fixedAt,
            enabled: enabled,
            chemicalState: enabled ? state.chemicalState : .neutral,
            bodySchema: enabled ? state.bodySchema : .neutral,
            fieldSummary: enabled ? state.field.summary() : .empty,
            predictionSummary: enabled ? state.predictionLedger.summary() : .empty,
            dreamRepairSummary: enabled ? state.dreamRepairState.summary() : .empty,
            residualRepairOpportunity: enabled ? OrganismResidualRepair.opportunity(
                ledger: state.predictionLedger,
                field: state.field,
                repairState: state.dreamRepairState,
                lastSignalAt: state.lastSignalAt,
                at: fixedAt
            ) : .empty(at: fixedAt),
            capabilityBeliefs: enabled ? OrganismCapabilitySelfModel.beliefs(ledger: state.predictionLedger, at: fixedAt) : [],
            projectedBodyLine: projection.bodyLine,
            signalCount: enabled ? state.signalCount : 0,
            lastSignalAt: enabled ? state.lastSignalAt : nil
        )
        return OrganismFrozenRead(
            fixedAt: fixedAt,
            snapshot: snapshot,
            projection: projection,
            posture: OrganismBehaviorPosture.from(snapshot: snapshot),
            toward: enabled ? OrganismHorizonRegister.toward(in: state.predictionLedger, at: fixedAt) : nil
        )
    }

    public func exportPersistentState() -> OrganismPersistentState? {
        guard configuration.enabled else { return nil }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        // savedAt uses the settle anchor so restore cannot decay an already settled interval twice.
        return body
    }

    /// Save disabled bodies dormant with their last settled anchor so later enable/restore spends elapsed time exactly once.
    public func exportContinuity() -> OrganismPersistentState {
        if configuration.enabled { settleElapsedTime(at: dependencies.now()) }
        return body
    }

    public func hasCompletedDream(_ id: UUID) -> Bool {
        body.dreamCompletions?.contains(id) == true
    }

    /// The epoch with the kernel's mutation revision, read in one actor turn: the revision orders publications of the epoch (a reset rollback can lawfully
    /// return the old epoch at a newer revision).
    public func epochAtRevision() -> (epoch: UInt64, revision: UInt64) {
        (body.epoch, mutationRevision)
    }

    /// Restores whether or not the body's effects are enabled (a disabled body restores dormant), so enabling it later never reloads the file.
    public func restorePersistentState(_ state: OrganismPersistentState) {
        let now = dependencies.now()
        wakefulnessFatigue = 0
        body = state.decayed(at: now, fatigueDecayLimit: OrganismPersistentState.maximumDecayHours * 3_600)
        body.schemaVersion = 1
        // Keep the future instant already settled through so runtime settlement never spends it twice.
        body.savedAt = max(now, state.savedAt)
        publishPredictedToolGroups()
    }

    public func settleContinuity() {
        guard configuration.enabled else { return }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        wakefulnessFatigue = OrganismChemistry.relaxedFatigue(wakefulnessFatigue, elapsed: 6 * 3_600)
        // Relax the chemistry now. This is not six hours of observed body time: fields, pending predictions and the persisted clock keep their real age.
        body.chemicalState = OrganismPersistentState.decayedChemistry(
            body.chemicalState, hours: 6, tendernessHours: 6, fatigueElapsed: 6 * 3_600)
        body.savedAt = now
        publishPredictedToolGroups()
    }

    public func clearTransientState() {
        // Forget chemistry and encounters together; retain the watermark and refuse moments from the old epoch.
        body = OrganismPersistentState(savedAt: dependencies.now(), epoch: body.epoch &+ 1, lived: body.lived)
        pendingResolutionFelt.removeAll()
        wakefulnessFatigue = 0
        publishPredictedToolGroups()
    }

    public struct ContinuityMutation: Sendable {
        fileprivate let before: OrganismPersistentState
        fileprivate let revision: UInt64
    }

    /// Capture, mutate and claim the resulting revision in one actor turn.
    public func beginContinuityMutation(reset: Bool) -> ContinuityMutation? {
        guard let before = exportPersistentState() else { return nil }
        if reset { clearTransientState() } else { settleContinuity() }
        return ContinuityMutation(before: before, revision: mutationRevision)
    }

    public func rollbackContinuityMutation(_ mutation: ContinuityMutation) -> Bool {
        guard mutationRevision == mutation.revision else { return false }
        restorePersistentState(mutation.before)
        return true
    }

    /// Gate enabled body, admission epoch and fold watermark, then atomically apply dose/reaction/correction with proof. Existing encounters extend their
    /// window; older caring turns cannot create a new encounter.
    public func foldTurn(_ fold: OrganismTurnFold) -> OrganismTurnFoldOutcome {
        guard configuration.enabled else { return .refused }
        // A moment from before the body's last forgetting lives in a body that no longer exists.
        guard fold.epoch == body.epoch else { return .forgotten }
        // Already lived: its whole share is in this body (and saved with it).
        if body.lived >= fold.seq { return .alreadyLived }
        settleElapsedTime(at: dependencies.now())
        var caring: OrganismCaringEventOutcome?
        if let reading = fold.caring {
            let opens = body.caringEncounter.opensNewEncounter(at: reading.at, window: fold.caringWindow)
            body.caringEncounter.extend(to: reading.at)
            if opens {
                body.chemicalState.tenderness = OrganismChemistry.dosedByCaringEvent(body.chemicalState.tenderness)
                noteRecentDose(CaringAppraisalRequest.RecentEncounter(
                    kind: reading.kind, at: reading.at, why: fold.caringWhy))
                caring = .dosed
            } else {
                caring = .coalesced
            }
        }
        if let reaction = fold.reaction {
            liveAfterTurnReaction(reaction, correctionConfidence: fold.correctionConfidence)
        }
        body.lived = fold.seq
        return .lived(caring: caring)
    }

    /// Actual doses remain in arrival order for relay judgment.
    public func recentDoses() -> [CaringAppraisalRequest.RecentEncounter] {
        body.caringEncounter.recentDoses ?? []
    }

    private func noteRecentDose(_ dose: CaringAppraisalRequest.RecentEncounter) {
        var doses = body.caringEncounter.recentDoses ?? []
        doses.append(dose)
        let horizon = dose.at.addingTimeInterval(-OrganismCaringEvent.relayEncounterWindow)
        doses.removeAll { $0.at < horizon }
        if doses.count > OrganismCaringEvent.recentDoseCap { doses.removeFirst(doses.count - OrganismCaringEvent.recentDoseCap) }
        body.caringEncounter.recentDoses = doses
    }

    /// Only human causes move curiosity, coherence, agency and confidence; positive doses saturate while negative doses lower.
    public func admitHumanCause(
        curiosity: Double = 0, coherence: Double = 0, agency: Double = 0, confidence: Double = 0
    ) {
        guard configuration.enabled else { return }
        settleElapsedTime(at: dependencies.now())
        body.chemicalState.curiosity = OrganismChemistry.raise(body.chemicalState.curiosity, by: curiosity)
        body.chemicalState.coherence = OrganismChemistry.raise(body.chemicalState.coherence, by: coherence)
        body.chemicalState.agency = OrganismChemistry.raise(body.chemicalState.agency, by: agency)
        body.chemicalState.confidence = OrganismChemistry.raise(body.chemicalState.confidence, by: confidence)
    }

    private func settleElapsedTime(at now: Date, deferringPredictionExpiry deferredIDs: Set<String> = []) {
        let elapsed = now.timeIntervalSince(body.savedAt)
        guard elapsed >= Self.minimumRuntimeDecayInterval else { return }
        var next = body.decayed(at: now, settleBodySchema: false, deferringPredictionExpiry: deferredIDs)
        // Only observed wall time accrues the separately capped wakefulness share.
        let awake = OrganismChemistry.wakefulness(wakefulnessFatigue, elapsed: elapsed)
        next.chemicalState.fatigue = (next.chemicalState.fatigue + awake.gain).clamped01()
        wakefulnessFatigue = awake.share
        body = next
        publishPredictedToolGroups()
    }

    private func publishPredictedToolGroups() {
        guard configuration.enabled else {
            dependencies.predictedToolGroupsSink([])
            return
        }
        dependencies.predictedToolGroupsSink(
            OrganismProspectiveAffect.predictedToolGroups(
                ledger: body.predictionLedger
            )
        )
    }

    private func currentResidualRepairOpportunity(at now: Date, satisfyWait: Bool = false) -> OrganismResidualRepairOpportunity {
        OrganismResidualRepair.opportunity(
            ledger: body.predictionLedger,
            field: body.field,
            repairState: body.dreamRepairState,
            lastSignalAt: body.lastSignalAt,
            at: now,
            satisfyWait: satisfyWait
        )
    }
}

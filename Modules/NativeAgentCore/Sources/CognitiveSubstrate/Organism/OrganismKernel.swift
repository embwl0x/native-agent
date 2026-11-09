import Foundation
import PersistenceCore
// Blueprint: | `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `foldTurn` (the body's whole share of one lived moment, with its watermark) |

public struct OrganismDependencies: Sendable {
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    /// Bounded immutable projection of pending tool expectations. The kernel still owns the prediction ledger; readers receive no mutation handle.
    public var predictedToolGroupsSink: @Sendable (Set<String>) -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        predictedToolGroupsSink: @escaping @Sendable (Set<String>) -> Void = { _ in }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.predictedToolGroupsSink = predictedToolGroupsSink
    }

    public static let live = OrganismDependencies()
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
        dependencies: OrganismDependencies = .live,
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
    private func liveAfterTurnReaction(_ signal: SomaticSignal) {
        guard signal.metadata[OrganismSemanticExpectation.reactionMetadataKey] != nil else { return }
        let before = body.predictionLedger
        var next = body
        OrganismPredictiveBody.resolveSemanticExpectations(
            signal: signal, ledger: &next.predictionLedger, chemicalState: &next.chemicalState)
        let felt = OrganismResolutionFelt.events(before: before, after: next.predictionLedger, at: dependencies.now())
        next.predictionLedger = felt.stamped
        body = next
        pendingResolutionFelt.append(contentsOf: felt.events)
        if pendingResolutionFelt.count > Self.pendingResolutionFeltCap {
            pendingResolutionFelt.removeFirst(pendingResolutionFelt.count - Self.pendingResolutionFeltCap)
        }
    }

    /// Infrastructure signals may update health, predictions and field while feelings follow time alone.
    public func ingest(_ signal: SomaticSignal, movesFeelings: Bool = true) async {
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
        let feltBefore = body.chemicalState
        defer { if !movesFeelings { body.chemicalState = feltBefore } }
        // Signal density uses ingest time; a nil first gap receives the per-signal share without claiming elapsed time.
        let elapsedSinceLastSignal = body.lastSignalAt.map {
            max(0, ingestedAt.timeIntervalSince($0))
        }
        let updated = OrganismChemistry.applying(
            signal: bounded,
            to: body.chemicalState,
            bodySchema: body.bodySchema,
            elapsedSinceLastSignal: elapsedSinceLastSignal
        )
        let ledgerBefore = body.predictionLedger
        let predicted = OrganismPredictiveBody.applying(
            signal: bounded,
            to: body.predictionLedger,
            chemicalState: updated.chemicalState
        )
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
        body.chemicalState = predicted.chemicalState
        body.bodySchema = updated.bodySchema
        body.field = OrganismPlasticity.applying(
            signal: bounded,
            chemicalState: predicted.chemicalState,
            bodySchema: updated.bodySchema,
            to: body.field
        )
        let repaired = OrganismDreamRepair.applying(
            signal: bounded,
            to: body.field,
            state: body.dreamRepairState,
            makeUUID: dependencies.makeUUID
        )
        body.field = repaired.field
        body.dreamRepairState = repaired.state
        if bounded.kind == .dreamCompleted || bounded.kind == .remIntegrated {
            // Dream completion resets the separately held wakefulness share as well as reducing total fatigue.
            wakefulnessFatigue = 0
            if bounded.kind == .dreamCompleted {
                if body.dreamCompletions == nil { body.dreamCompletions = [] }
                body.dreamCompletions?.insert(bounded.id)
            }
        }
        body.signalCount = min(body.signalCount, Int.max - 1) + 1
        // Quiet physiology follows when the signal reached this organism, not an untrusted/delayed source timestamp. The anchor is monotonic so an out-of-order
        // event can never make repair run early.
        body.lastSignalAt = max(body.lastSignalAt ?? .distantPast, ingestedAt)
        publishPredictedToolGroups()
    }

    public func refreshBodySchema(
        _ read: OrganismBodyRead,
        integratesChemistry: Bool = true,
        canonicalAffect: OrganismLifeReading? = nil
    ) async {
        applyBodySchema(
            read,
            integratesChemistry: integratesChemistry,
            canonicalAffect: canonicalAffect,
            at: dependencies.now()
        )
    }

    /// Apply the body sample and produce the turn's fixed-time organism value in one actor admission. Cognition's canonical warmth and pressure cross together;
    /// the returned read remains mutation-free and advisory.
    public func refreshBodySchemaAndFrozenRead(
        _ read: OrganismBodyRead,
        integratesChemistry: Bool = true,
        canonicalAffect: OrganismLifeReading? = nil,
        fixedAt: Date
    ) -> OrganismFrozenRead {
        applyBodySchema(
            read,
            integratesChemistry: integratesChemistry,
            canonicalAffect: canonicalAffect,
            at: fixedAt
        )
        return frozenRead(at: fixedAt)
    }

    private func applyBodySchema(
        _ read: OrganismBodyRead,
        integratesChemistry: Bool,
        canonicalAffect: OrganismLifeReading?,
        at observedAt: Date
    ) {
        guard configuration.enabled else { return }
        settleElapsedTime(at: observedAt)
        let nextBodySchema = OrganismBodySchemaSampler.bodySchema(
            from: read,
            previous: body.bodySchema,
            now: observedAt
        )
        if integratesChemistry {
            body.chemicalState = OrganismChemistry.integrating(
                bodySchema: nextBodySchema,
                previous: body.bodySchema,
                into: body.chemicalState
            )
        }
        body.bodySchema = nextBodySchema
        if let canonicalAffect {
            let affect = canonicalAffect.affect
            body.chemicalState.warmth = affect.socialWarmth.clamped01()
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
            anticipated,
            at: now,
            clock: configuration.diurnalClock
        )
        return OrganismChemistry.projection(
            at: now,
            chemicalState: daily.state,
            bodySchema: bodySchema,
            diurnal: daily.read,
            tenderNamed: body.caringEncounter.lastCaringTurnAt.map {
                now.timeIntervalSince($0) < OrganismChemistry.tenderNamedWindow
            } ?? false
        )
    }

    /// The runtime pushes shared quiet-hour and clock changes before reads; the kernel owns no preference file or polling loop.
    public func configureDiurnalClock(_ clock: OrganismDiurnalClock?) {
        configuration.diurnalClock = clock
    }

    /// Read delivery outcomes from this live ledger; decoding its persisted snapshot would bypass newer resident evidence.
    public func latestPrediction(ofKind kind: OrganismPredictionKind) -> OrganismPrediction? {
        guard configuration.enabled else { return nil }
        return body.predictionLedger.predictions.values
            .filter { $0.kind == kind }
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

    /// Execute one already-due local repair pass. The result is false when the evidence decayed, a newer signal reset the quiet window, or no bounded field
    /// operation remained. It never recruits a model or dispatches work.
    @discardableResult
    public func runResidualRepairIfDue(satisfyWait: Bool = false) async -> Bool {
        guard configuration.enabled else { return false }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let opportunity = currentResidualRepairOpportunity(at: now, satisfyWait: satisfyWait)
        guard opportunity.ready else { return false }
        let previous = body.dreamRepairState
        let repaired = OrganismDreamRepair.applyingResidualPressure(
            opportunity,
            at: now,
            to: body.field,
            state: body.dreamRepairState,
            makeUUID: dependencies.makeUUID
        )
        body.field = repaired.field
        body.dreamRepairState = repaired.state
        return body.dreamRepairState != previous
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

    public func behaviorPosture() async -> OrganismBehaviorPosture? {
        OrganismBehaviorPosture.from(snapshot: await snapshot())
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

    /// The epoch a moment must be stamped with for this body to live it.
    public func epoch() -> UInt64 { body.epoch }

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
        if let reaction = fold.reaction { liveAfterTurnReaction(reaction) }
        if fold.correctionConfidence > 0 {
            body.chemicalState.confidence = OrganismChemistry.raise(body.chemicalState.confidence, by: fold.correctionConfidence)
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
        curiosity: Double = 0, coherence: Double = 0, agency: Double = 0, confidence: Double = 0,
        epoch: UInt64? = nil
    ) {
        guard configuration.enabled else { return }
        // A cause from a turn admitted before the body's last forgetting.
        if let epoch, epoch != body.epoch { return }
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

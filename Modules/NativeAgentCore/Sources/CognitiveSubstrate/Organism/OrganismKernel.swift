import Foundation
import PersistenceCore
// Blueprint: | `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `foldTurn` (the body's whole share of one lived moment, with its watermark) |

public struct OrganismDependencies: Sendable {
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    /// Bounded immutable projection of pending tool expectations. The kernel
    /// still owns the prediction ledger; readers receive no mutation handle.
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
    /// When the canonical relational crossing last integrated tenderness.
    /// In-memory: a gap the process did not observe is missing evidence, so a
    /// restart resumes integrating from the next crossing rather than claiming
    /// the whole downtime as sustained warmth.
    private var tendernessAnchorAt: Date? { didSet { mutationRevision &+= 1 } }
    /// How much of the fatigue axis the WAKEFULNESS lane currently holds
    /// (0…`OrganismChemistry.wakefulnessShareCap`). Tracked apart from the
    /// total so hours-awake can be capped without capping work.
    ///
    /// In-memory: a restart is missing evidence, not proof she slept, but it is
    /// equally not proof she was awake — and a process that was not running
    /// cannot attest to hours. Resuming from zero is the conservative read, and
    /// the dream resets it anyway.
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

    /// The person's reaction to her last completion settles the expectation it
    /// answers (part of `foldTurn`).
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

    /// `movesFeelings: false`, decided at signal admission: the
    /// signal still updates the body schema, predictions and field —
    /// health and ops posture — but leaves the ten feeling axes where time
    /// alone left them.
    public func ingest(_ signal: SomaticSignal, movesFeelings: Bool = true) async {
        guard configuration.enabled else { return }
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
        // Horizon refresh updates horizons and earned chemistry release without recording traffic or consuming quiet time.
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
        // Notable resolutions carry aboutness into the substrate through a
        // rate-stamped ledger diff and a bounded drain buffer.
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
            // SLEEP RESETS HOURS AWAKE. The chemistry arm already takes 0.08 off
            // the total; this is what makes "how long have I been up" start
            // counting again from zero.
            wakefulnessFatigue = 0
        }
        body.signalCount = min(body.signalCount, Int.max - 1) + 1
        // Quiet physiology follows when the signal reached this organism, not
        // an untrusted/delayed source timestamp. The anchor is monotonic so an
        // out-of-order event can never make repair run early.
        body.lastSignalAt = max(body.lastSignalAt ?? .distantPast, ingestedAt)
        publishPredictedToolGroups()
    }

    public func refreshBodySchema(
        _ read: OrganismBodyRead,
        integratesChemistry: Bool = true,
        canonicalAffect: CognitiveAffectState? = nil
    ) async {
        applyBodySchema(
            read,
            integratesChemistry: integratesChemistry,
            canonicalAffect: canonicalAffect,
            at: dependencies.now()
        )
    }

    /// Apply the body sample and produce the turn's fixed-time organism value
    /// in one actor admission. Cognition's canonical warmth and pressure cross
    /// together; the returned read remains mutation-free and advisory.
    public func refreshBodySchemaAndFrozenRead(
        _ read: OrganismBodyRead,
        integratesChemistry: Bool = true,
        canonicalAffect: CognitiveAffectState? = nil,
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
        canonicalAffect: CognitiveAffectState?,
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
            body.chemicalState.warmth = canonicalAffect.socialWarmth.clamped01()
            body.chemicalState.urgency = canonicalAffect.taskPressure.clamped01()
            // Elapsed since the last CROSSING, not since the last read: an
            // Observatory poll at the same instant integrates exactly nothing.
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

    /// The app layer pushes declared quiet hours (`data/user_prefs.json` →
    /// `quiet_hours`, also read by the turn engine) on the Mac's clock.
    /// The kernel never reads a file and owns no preference store.
    ///
    /// The runtime pushes preference/clock invalidations before body reads;
    /// the kernel never schedules a preference rescan.
    public func configureDiurnalClock(_ clock: OrganismDiurnalClock?) {
        configuration.diurnalClock = clock
    }

    /// Bounded live owner read for body projections that need the latest
    /// device-delivery outcome. Callers must not decode the kernel's persisted
    /// snapshot behind its back: continuity is restored into this ledger at
    /// bootstrap, and this actor remains the sole live owner afterward.
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

    /// Pure cumulative capability read for body projections that must survive
    /// a restart before their transient lifecycle sensor has been restored.
    public func capabilityBelief(ofKind kind: OrganismPredictionKind) -> OrganismCapabilityBelief? {
        guard configuration.enabled else { return nil }
        return OrganismCapabilitySelfModel.beliefs(
            ledger: body.predictionLedger,
            at: dependencies.now()
        ).first { $0.kind == kind }
    }

    /// Pure deadline read for event-driven repair. No timer is owned by the
    /// kernel and no state is changed beyond ordinary analytic settlement.
    public func residualRepairOpportunity() async -> OrganismResidualRepairOpportunity {
        guard configuration.enabled else { return .empty(at: dependencies.now()) }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        return currentResidualRepairOpportunity(at: now)
    }

    /// Execute one already-due local repair pass. The result is false when the
    /// evidence decayed, a newer signal reset the quiet window, or no bounded
    /// field operation remained. It never recruits a model or dispatches work.
    @discardableResult
    public func runResidualRepairIfDue() async -> Bool {
        guard configuration.enabled else { return false }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let opportunity = currentResidualRepairOpportunity(at: now)
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

    /// Drains felt resolutions (relief / disappointment) minted since the
    /// last drain. The caller (NativeCognitionRuntime) turns each into a
    /// substrate event with the resolved organ as aboutness.
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

    /// Build a production-equivalent projection/posture from a copied state at
    /// one explicit time. Unlike `snapshot()`/`projection()`, this never settles
    /// or rewrites the live kernel.
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

    /// The body's continuity for its file, whether or not its effects are
    /// enabled. A disabled body is DORMANT: it takes no signals and no doses,
    /// its state is kept and saved, and its saved anchor stays where time last
    /// settled it so the next restore or enable spends the gap once.
    public func exportContinuity() -> OrganismPersistentState {
        if configuration.enabled { settleElapsedTime(at: dependencies.now()) }
        return body
    }

    /// The epoch a moment must be stamped with for this body to live it.
    public func epoch() -> UInt64 { body.epoch }

    /// The epoch with the kernel's mutation revision, read in one actor turn:
    /// the revision orders publications of the epoch (a reset rollback can
    /// lawfully return the old epoch at a newer revision).
    public func epochAtRevision() -> (epoch: UInt64, revision: UInt64) {
        (body.epoch, mutationRevision)
    }

    /// Restores whether or not the body's effects are enabled (a disabled body
    /// restores dormant), so enabling it later never reloads the file.
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
        var state = body
        state.savedAt = now
        wakefulnessFatigue = OrganismChemistry.relaxedFatigue(wakefulnessFatigue, elapsed: 6 * 3_600)
        body = state.decayed(at: now.addingTimeInterval(6 * 3_600))
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

    /// THE BODY'S WHOLE SHARE OF ONE LIVED MOMENT, in one mutation
    /// (docs/SUBCONSCIOUS.md, "Lived moments"): the caring dose, the
    /// after-turn reaction and the correction cause land together and the body's
    /// watermark (`body.lived`) is stamped in the same actor turn, so a crash can
    /// never leave half of a moment in the body with its proof.
    ///
    /// THE GATES, in order: the body is on; the moment was admitted under this
    /// body's epoch; the body has not already lived this fold seq. Then the
    /// caring reading is measured against the encounter it arrives in: a new
    /// encounter doses (and is remembered for relay judgment), a reading inside
    /// the encounter already running rolls the window and does not dose. A
    /// reading older than the last caring turn seen is not evidence of a new
    /// encounter (`Encounter.opensNewEncounter`).
    public func foldTurn(_ fold: OrganismTurnFold) -> OrganismTurnFoldOutcome {
        guard configuration.enabled else { return .refused }
        // A moment from before the body's last forgetting lives in a body that
        // no longer exists.
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

    /// The encounters that recently dosed, newest last.
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

    /// A human cause moving a feeling — something she came back
    /// to with a better question (curiosity), an opinion she revised on
    /// evidence (coherence), her own work landing or failing (agency,
    /// confidence). Small doses; a raise saturates, a negative one lowers.
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

    private func currentResidualRepairOpportunity(at now: Date) -> OrganismResidualRepairOpportunity {
        OrganismResidualRepair.opportunity(
            ledger: body.predictionLedger,
            field: body.field,
            repairState: body.dreamRepairState,
            lastSignalAt: body.lastSignalAt,
            at: now
        )
    }
}

import CryptoKit
import Foundation
import PersistenceCore

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
    private var configuration: OrganismConfiguration
    private let dependencies: OrganismDependencies
    private var chemicalState: ChemicalState
    private var bodySchema: BodySchema
    private var field: OrganismField
    private var predictionLedger: OrganismPredictionLedger
    private var dreamRepairState: OrganismDreamRepairState
    private var reflexState: OrganismReflexState
    private var signalCount: Int = 0
    /// Round 3 Wave A2 — felt resolutions awaiting the runtime's drain.
    /// Capped (drop-oldest); the drain is the remove for every add.
    private static let pendingResolutionFeltCap = 8
    private var pendingResolutionFelt: [OrganismResolutionFeltEvent] = []
    private var lastSignalAt: Date?
    private var lastSettledAt: Date
    /// When the canonical relational crossing last integrated tenderness.
    /// In-memory: a gap the process did not observe is missing evidence, so a
    /// restart resumes integrating from the next crossing rather than claiming
    /// the whole downtime as sustained warmth.
    private var tendernessAnchorAt: Date?
    /// When the app layer last pushed the user's quiet-hours preference into
    /// `configuration.diurnalClock`. In-memory only: a clock is a read of a
    /// preference file, never state the body owns.
    private var diurnalClockReadAt: Date?
    /// How much of the fatigue axis the WAKEFULNESS lane currently holds
    /// (0…`OrganismChemistry.wakefulnessShareCap`). Tracked apart from the
    /// total so hours-awake can be capped without capping work.
    ///
    /// In-memory: a restart is missing evidence, not proof she slept, but it is
    /// equally not proof she was awake — and a process that was not running
    /// cannot attest to hours. Resuming from zero is the conservative read, and
    /// the dream resets it anyway.
    private var wakefulnessFatigue: Double = 0
    /// Caring moments already SEEN, by originating conversational event
    /// (`OrganismCaringEvent.key`). Seen, not dosed: a moment coalesced into an
    /// encounter already running is in here too, because the question this ring
    /// answers is "have I counted this turn", and the answer has to be yes
    /// whichever way it was counted. A bounded insertion-ordered ring — see
    /// `OrganismCaringEvent.maximumRememberedKeys` for why it is bounded, small,
    /// and deliberately not persisted.
    private var countedCaringEventKeys: Set<String> = []
    private var countedCaringEventKeyOrder: [String] = []
    /// ONE ENCOUNTER, ONE DOSE (2026-09-11). The rolling window the caring
    /// coalescing measures against. Unlike the ring above this IS persisted, in
    /// `OrganismPersistentState.caringEncounter` — see `OrganismCaringEvent.Encounter`.
    private var caringEncounter: OrganismCaringEvent.Encounter = .empty
    private static let minimumRuntimeDecayInterval: TimeInterval = 1

    public init(
        configuration: OrganismConfiguration = .disabled,
        dependencies: OrganismDependencies = .live,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral,
        field: OrganismField = .empty,
        predictionLedger: OrganismPredictionLedger = .empty,
        dreamRepairState: OrganismDreamRepairState = .empty,
        reflexState: OrganismReflexState = .empty
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
        self.field = field
        self.predictionLedger = predictionLedger
        self.dreamRepairState = dreamRepairState
        self.reflexState = reflexState
        self.lastSettledAt = dependencies.now()
    }

    public func configure(_ configuration: OrganismConfiguration) async {
        let now = dependencies.now()
        // Settle owed wall-time first, and never move the anchor backward:
        // settleContinuity() parks lastSettledAt in the future after its forward
        // decay, and resetting it to now would re-apply hours that were already
        // decayed (the F3-M5 double-decay bug, re-fixed 2026-08-21).
        settleElapsedTime(at: now)
        self.configuration = configuration
        lastSettledAt = max(lastSettledAt, now)
        publishPredictedToolGroups(at: lastSettledAt)
    }

    public func ingest(_ signal: SomaticSignal) async {
        guard configuration.enabled else { return }
        let ingestedAt = dependencies.now()
        // Item 5 (2026-09-02): a horizon refresh is not something that HAPPENED
        // to her, so it takes none of the path below. It is her looking at her
        // own calendar, and the ordinary ingest tail would quietly make that an
        // event: `settleElapsedTime` would consume the quiet window the residual
        // repair lane is measuring, `signalCount`/`lastSignalAt` would report
        // traffic on an idle machine (and reset the quiet clock that decides
        // when repair is due), `publishPredictedToolGroups` would republish, and
        // `OrganismPlasticity` would bump the field's mutation generation on
        // every deadline pass. None of that is true of reading a calendar.
        //
        // What DOES run is the horizon lane itself: mint, refresh, settle the
        // vanished, expire the passed, and the chemistry release that a dreaded
        // thing landing early legitimately produces. Nothing else.
        if signal.kind == .horizonRefresh {
            let refreshed = OrganismPredictiveBody.applyingHorizonRefresh(
                signal: SomaticSignal(
                    id: signal.id,
                    kind: signal.kind,
                    sourceOrgan: signal.sourceOrgan,
                    occurredAt: signal.occurredAt,
                    intensity: signal.intensity,
                    valence: signal.valence,
                    arousal: signal.arousal,
                    metadata: signal.metadata,
                    bounds: configuration.metadataBounds
                ),
                to: predictionLedger,
                chemicalState: chemicalState,
                at: ingestedAt
            )
            predictionLedger = refreshed.ledger
            chemicalState = refreshed.chemicalState
            return
        }
        settleElapsedTime(at: ingestedAt)
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
        // The homeostatic settle is budgeted per wall-clock hour, so it needs to
        // know how dense the traffic is. `lastSignalAt` is the honest anchor:
        // it is stamped at the END of this function from the INGEST clock, so a
        // delayed or out-of-order source timestamp cannot widen the gap and buy
        // extra relaxation.
        //
        // NIL, NOT ZERO, for the first signal after a fresh start (review fix,
        // 2026-09-02). Collapsing "no previous signal" to a zero-second gap made
        // the density cap read as "this hour has earned nothing", so the first
        // signal of a session settled nothing and — once item 4 landed — accrued
        // no fatigue either. Nil is the honest report of an absent gap, and both
        // laws already define it: the per-signal share, with no density claim
        // attached.
        let elapsedSinceLastSignal = lastSignalAt.map {
            max(0, ingestedAt.timeIntervalSince($0))
        }
        let updated = OrganismChemistry.applying(
            signal: bounded,
            to: chemicalState,
            bodySchema: bodySchema,
            elapsedSinceLastSignal: elapsedSinceLastSignal
        )
        let ledgerBefore = predictionLedger
        let predicted = OrganismPredictiveBody.applying(
            signal: bounded,
            to: predictionLedger,
            chemicalState: updated.chemicalState,
            bodySchema: updated.bodySchema,
            limits: configuration.predictionLimits
        )
        // Round 3 Wave A2: notable resolutions become FELT events the runtime
        // drains into the substrate (relief / earned disappointment, with the
        // resolved organ as aboutness). Pure diff + rate stamps; buffer is
        // capped so an undrained kernel can never grow without bound.
        let felt = OrganismResolutionFelt.events(
            before: ledgerBefore,
            after: predicted.ledger,
            at: ingestedAt
        )
        predictionLedger = felt.stamped
        pendingResolutionFelt.append(contentsOf: felt.events)
        if pendingResolutionFelt.count > Self.pendingResolutionFeltCap {
            pendingResolutionFelt.removeFirst(pendingResolutionFelt.count - Self.pendingResolutionFeltCap)
        }
        chemicalState = predicted.chemicalState
        bodySchema = predicted.bodySchema
        field = OrganismPlasticity.applying(
            signal: bounded,
            chemicalState: predicted.chemicalState,
            bodySchema: predicted.bodySchema,
            to: field,
            limits: configuration.fieldLimits
        )
        let repaired = OrganismDreamRepair.applying(
            signal: bounded,
            to: field,
            state: dreamRepairState,
            limits: configuration.dreamRepairLimits,
            makeUUID: dependencies.makeUUID
        )
        field = repaired.field
        dreamRepairState = repaired.state
        if bounded.kind == .dreamCompleted || bounded.kind == .remIntegrated {
            // SLEEP RESETS HOURS AWAKE. The chemistry arm already takes 0.08 off
            // the total; this is what makes "how long have I been up" start
            // counting again from zero.
            wakefulnessFatigue = 0
        }
        if bounded.kind == .dreamCompleted {
            // Conservative provider-budget accounting: the organism receives
            // this signal only after the canonical Dream owner commits. A
            // pressure proposal by itself never advances the refractory gate.
            dreamRepairState.sleepControl = OrganismOperationalConsolidator
                .recordingAcceptedIdentityDream(
                    in: dreamRepairState.sleepControl,
                    at: ingestedAt
                )
        }
        // Only canonical chat-tool outcomes carry a checked risk class. Those
        // are the producer contract for reviewable reflexes: generic motor,
        // provider, and Desk signals still affect prediction/chemistry/body
        // schema above but cannot manufacture a proposal from unclassified
        // telemetry. This keeps the human review surface live for its one
        // declared producer without broadening it into a prose reflex engine.
        if case .string(let rawRisk)? = bounded.metadata["trustRisk"],
           ["low", "medium", "high", "critical"].contains(
                rawRisk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
           ),
           bounded.kind == .toolSucceeded || bounded.kind == .toolFailed {
            reflexState = OrganismReflexCompiler.applying(
                signal: bounded,
                to: reflexState,
                limits: configuration.reflexLimits
            )
        }
        signalCount += 1
        // Quiet physiology follows when the signal reached this organism, not
        // an untrusted/delayed source timestamp. The anchor is monotonic so an
        // out-of-order event can never make repair run early.
        lastSignalAt = max(lastSignalAt ?? .distantPast, ingestedAt)
        publishPredictedToolGroups(at: ingestedAt)
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
            previous: bodySchema,
            now: observedAt
        )
        if integratesChemistry {
            chemicalState = OrganismChemistry.integrating(
                bodySchema: nextBodySchema,
                previous: bodySchema,
                into: chemicalState
            )
        }
        bodySchema = nextBodySchema
        if let canonicalAffect {
            chemicalState.warmth = ChemicalState.clamp(canonicalAffect.socialWarmth)
            chemicalState.urgency = ChemicalState.clamp(canonicalAffect.taskPressure)
            // Elapsed since the last CROSSING, not since the last read: an
            // Observatory poll at the same instant integrates exactly nothing.
            chemicalState.tenderness = OrganismChemistry.tenderness(
                chemicalState.tenderness,
                underCanonicalWarmth: chemicalState.warmth,
                elapsed: tendernessAnchorAt.map {
                    max(0, observedAt.timeIntervalSince($0))
                } ?? 0
            )
            tendernessAnchorAt = observedAt
        }
    }

    public func projection() async -> OrganismProjection {
        guard configuration.enabled else {
            return OrganismProjection(generatedAt: dependencies.now())
        }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        // R2-D (2026-07-09): ANTICIPATORY AFFECT — the body braces before the future
        // arrives. Pending predictions modulate the PROJECTED chemistry (never the
        // stored state): a near-due, low-confidence expectation raises vigilance and
        // dips confidence (bracing); confident positive expectations lift curiosity
        // (looking-forward). The felt fingerprint inherits it through the existing
        // chem→FeltSignals mapping — no new capsule text, no new senses; no pending
        // predictions → byte-identical projection.
        let anticipated = OrganismProspectiveAffect.modulate(
            chemicalState,
            ledger: predictionLedger,
            at: now
        )
        // Item 4 (2026-09-02) — THE CLOCK, layered on the same PROJECTION-ONLY
        // seam anticipatory affect uses. No clock configured → identical bytes.
        let daily = OrganismCircadian.modulate(
            anticipated,
            at: now,
            clock: configuration.diurnalClock
        )
        return OrganismChemistry.projection(
            at: now,
            chemicalState: daily.state,
            bodySchema: bodySchema,
            // The clock reaches the "- Body:" line too: a tired body near the
            // trough reads as the night rather than as a long day.
            diurnal: daily.read
        )
    }

    /// Item 4's one door for the body's clock. The app layer pushes the user's
    /// ALREADY-DECLARED quiet hours (`data/user_prefs.json` → `quiet_hours`, the
    /// same source the turn engine's clock line reads) plus their time zone; the
    /// kernel never reads a file and owns no config of its own.
    ///
    /// Paired with `diurnalClockIsStale(at:)` so the caller can re-read the
    /// preference on a slow cadence instead of on every body sample.
    public func configureDiurnalClock(_ clock: OrganismDiurnalClock?, at now: Date? = nil) {
        configuration.diurnalClock = clock
        diurnalClockReadAt = now ?? dependencies.now()
    }

    /// Whether the pushed clock is older than `ttl`. Quiet hours change roughly
    /// never; re-reading the preference file on every tool result would be a
    /// stat storm for a value with a five-minute-stale tolerance of infinity.
    public func diurnalClockIsStale(at now: Date, ttl: TimeInterval = 300) -> Bool {
        guard configuration.enabled else { return false }
        guard let readAt = diurnalClockReadAt else { return true }
        return now.timeIntervalSince(readAt) >= ttl
    }

    /// How much of the current fatigue is hours-awake rather than work. Pure
    /// read for the Observatory and for tests.
    public func wakefulnessShare() -> Double { wakefulnessFatigue }

    /// Mind-into-circulation (2026-07-10): a PURE read of what tool families the body
    /// is currently bracing for → bounded tool-group query terms for Fluid Context's
    /// NeedSignal.predictedToolGroups. Pending TOOL expectations only; provider/phone/
    /// approval/workflow expectations and stale (past-due or resolved/expired) ones
    /// contribute nothing. Disabled organism or empty ledger → empty set. Never mutates
    /// state. Mirrors projection()/snapshot()'s exposure and now-injection.
    public func predictedToolGroups() async -> Set<String> {
        guard !Task.isCancelled, configuration.enabled else { return [] }
        return OrganismProspectiveAffect.predictedToolGroups(
            ledger: predictionLedger,
            at: dependencies.now()
        )
    }

    /// Bounded live owner read for body projections that need the latest
    /// device-delivery outcome. Callers must not decode the kernel's persisted
    /// snapshot behind its back: continuity is restored into this ledger at
    /// bootstrap, and this actor remains the sole live owner afterward.
    public func latestPrediction(ofKind kind: OrganismPredictionKind) -> OrganismPrediction? {
        guard configuration.enabled else { return nil }
        return predictionLedger.predictions.values
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
        return predictionLedger.predictions[id]
    }

    /// Pure cumulative capability read for body projections that must survive
    /// a restart before their transient lifecycle sensor has been restored.
    public func capabilityBelief(ofKind kind: OrganismPredictionKind) -> OrganismCapabilityBelief? {
        guard configuration.enabled else { return nil }
        return OrganismCapabilitySelfModel.beliefs(
            ledger: predictionLedger,
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
        let previous = dreamRepairState
        let repaired = OrganismDreamRepair.applyingResidualPressure(
            opportunity,
            at: now,
            to: field,
            state: dreamRepairState,
            limits: configuration.dreamRepairLimits,
            makeUUID: dependencies.makeUUID
        )
        field = repaired.field
        dreamRepairState = repaired.state
        return dreamRepairState != previous
    }

    /// Execute the non-learning operational lane when exact pressure is due.
    /// The returned receipt is payload-free. Only refractory bookkeeping is
    /// persisted; no personal model statistic or confidence is updated.
    public func runOperationalConsolidationIfDue() async -> OrganismOperationalConsolidationReceipt? {
        guard configuration.enabled else { return nil }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let reading = currentResidualRepairOpportunity(at: now)
        guard let result = OrganismOperationalConsolidator.consolidate(
            reading,
            controlState: dreamRepairState.sleepControl,
            at: now
        ) else { return nil }
        dreamRepairState.sleepControl = result.controlState
        return result.receipt
    }

    /// Claim the identity-Dream lane for ONE dream, atomically. Returns the
    /// decision the lane reached; only `.fire` means the caller may proceed, and
    /// only in that case does the 24-hour refractory advance.
    ///
    /// The caller must have already passed its OWN provider/budget/trust gates
    /// before claiming (the lane's `.providerBudgetGateRequired` disposition is
    /// literally that instruction), so a claim means "committed to dream", not
    /// "eligible to dream". The claim is taken here rather than after the
    /// provider returns because two wakes racing the same eligible window must
    /// not both dream; a claimed dream that then fails at the provider does NOT
    /// release the window — 03:30 is the integrity fallback for exactly that,
    /// and an unbounded provider retry is not.
    public func claimIdentityDreamIfDue(
        turnInFlight: Bool
    ) async -> OrganismIdentityDreamTrigger.Decision {
        guard configuration.enabled else { return .belowThreshold }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let reading = currentResidualRepairOpportunity(at: now)
        let decision = OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: turnInFlight
        )
        guard decision == .fire else { return decision }
        dreamRepairState.sleepControl = OrganismOperationalConsolidator
            .recordingAcceptedIdentityDream(in: dreamRepairState.sleepControl, at: now)
        return .fire
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
        // Parity with projection(): the Observatory's projected body line reflects the
        // SAME anticipatory modulation the capsule feels — "capsule says braced, panel
        // says calm" is a diagnostics lie (gpt-5.5 review LOW, 2026-07-09). The raw
        // stored chemistry stays visible via `chemicalState` below.
        // Parity extends to the clock: a snapshot taken at 3 AM must read the
        // same dulled curiosity the capsule felt.
        let projection: OrganismProjection? = configuration.enabled
            ? {
                let daily = OrganismCircadian.modulate(
                    OrganismProspectiveAffect.modulate(
                        chemicalState, ledger: predictionLedger, at: now),
                    at: now,
                    clock: configuration.diurnalClock
                )
                return OrganismChemistry.projection(
                    at: now,
                    chemicalState: daily.state,
                    bodySchema: bodySchema,
                    diurnal: daily.read
                )
            }()
            : nil
        let residualRepair = configuration.enabled
            ? currentResidualRepairOpportunity(at: now)
            : .empty(at: now)
        let capabilityBeliefs = configuration.enabled
            ? OrganismCapabilitySelfModel.beliefs(ledger: predictionLedger, at: now)
            : []
        return OrganismSnapshot(
            generatedAt: now,
            enabled: configuration.enabled,
            chemicalState: configuration.enabled ? chemicalState : .neutral,
            bodySchema: configuration.enabled ? bodySchema : .neutral,
            fieldSummary: configuration.enabled ? field.summary() : .empty,
            predictionSummary: configuration.enabled ? predictionLedger.summary() : .empty,
            dreamRepairSummary: configuration.enabled ? dreamRepairState.summary() : .empty,
            reflexSummary: configuration.enabled ? reflexState.summary() : .empty,
            reflexCandidates: configuration.enabled ? reflexState.activeCandidates() : [],
            reflexReviewReceipts: configuration.enabled ? reflexState.recentReviewReceipts() : [],
            residualRepairOpportunity: residualRepair,
            capabilityBeliefs: capabilityBeliefs,
            projectedBodyLine: projection?.bodyLine,
            signalCount: configuration.enabled ? signalCount : 0,
            lastSignalAt: configuration.enabled ? lastSignalAt : nil
        )
    }

    public func behaviorPosture() async -> OrganismBehaviorPosture? {
        OrganismBehaviorPosture.from(snapshot: await snapshot())
    }

    /// Build a production-equivalent projection/posture from a copied state at
    /// one explicit time. Unlike `snapshot()`/`projection()`, this never settles
    /// or rewrites the live kernel.
    public func frozenRead(at fixedAt: Date) -> OrganismFrozenRead {
        let raw = currentPersistentState(savedAt: lastSettledAt)
        let frozen = configuration.enabled
            ? withFatigueClock(
                raw.decayed(at: fixedAt, settleBodySchema: false),
                from: raw.chemicalState.fatigue,
                elapsed: max(0, fixedAt.timeIntervalSince(lastSettledAt))
            ).state
            : raw
        let projection: OrganismProjection
        let snapshot: OrganismSnapshot
        if configuration.enabled {
            let anticipated = OrganismProspectiveAffect.modulate(
                frozen.chemicalState,
                ledger: frozen.predictionLedger,
                at: fixedAt
            )
            let daily = OrganismCircadian.modulate(
                anticipated,
                at: fixedAt,
                clock: configuration.diurnalClock
            )
            projection = OrganismChemistry.projection(
                at: fixedAt,
                chemicalState: daily.state,
                bodySchema: frozen.bodySchema,
                diurnal: daily.read
            )
            snapshot = OrganismSnapshot(
                generatedAt: fixedAt,
                enabled: true,
                chemicalState: frozen.chemicalState,
                bodySchema: frozen.bodySchema,
                fieldSummary: frozen.field.summary(),
                predictionSummary: frozen.predictionLedger.summary(),
                dreamRepairSummary: frozen.dreamRepairState.summary(),
                reflexSummary: frozen.reflexState.summary(),
                reflexCandidates: frozen.reflexState.activeCandidates(),
                reflexReviewReceipts: frozen.reflexState.recentReviewReceipts(),
                residualRepairOpportunity: OrganismResidualRepair.opportunity(
                    ledger: frozen.predictionLedger,
                    field: frozen.field,
                    repairState: frozen.dreamRepairState,
                    lastSignalAt: frozen.lastSignalAt,
                    at: fixedAt,
                    resourcePressure: frozen.bodySchema.resourcePressure
                ),
                capabilityBeliefs: OrganismCapabilitySelfModel.beliefs(
                    ledger: frozen.predictionLedger,
                    at: fixedAt
                ),
                projectedBodyLine: projection.bodyLine,
                signalCount: frozen.signalCount,
                lastSignalAt: frozen.lastSignalAt
            )
        } else {
            projection = OrganismProjection(generatedAt: fixedAt)
            snapshot = OrganismSnapshot(
                generatedAt: fixedAt,
                enabled: false,
                chemicalState: .neutral,
                bodySchema: .neutral,
                signalCount: 0,
                lastSignalAt: nil
            )
        }
        return OrganismFrozenRead(
            fixedAt: fixedAt,
            revisionFingerprint: revisionFingerprint(for: raw),
            snapshot: snapshot,
            projection: projection,
            posture: OrganismBehaviorPosture.from(snapshot: snapshot)
        )
    }

    /// Pure owner revision used after a provider epoch to detect any concurrent
    /// live mutation. It intentionally includes transient provider belief.
    public func frozenRevisionFingerprint() -> String {
        revisionFingerprint(for: currentPersistentState(savedAt: lastSettledAt))
    }

    public func exportPersistentState() async -> OrganismPersistentState? {
        guard configuration.enabled else { return nil }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        // 2026-07-23 audit fix (F3-M5): stamp savedAt at the settle anchor, not
        // `now`. After settleContinuity() forward-decays through now+6h and sets
        // lastSettledAt = now+6h, exporting with savedAt=now would let
        // restorePersistentState re-decay the already-forward-decayed 6h window
        // on relaunch inside 6h — the exact double-decay the 07-21 fix removed
        // for the in-memory path. lastSettledAt is the instant state has
        // actually been decayed through; decayed(at:) clamps elapsed to >= 0, so
        // a future-dated savedAt correctly yields zero decay until the wall
        // clock passes it. In the ordinary case (no recent settleContinuity)
        // lastSettledAt == now, so this is a no-op. Consistent with
        // frozenRevisionFingerprint(), which already uses savedAt=lastSettledAt.
        return OrganismPersistentState(
            savedAt: lastSettledAt,
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            field: field,
            predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState,
            reflexState: reflexState,
            signalCount: signalCount,
            lastSignalAt: lastSignalAt,
            caringEncounter: caringEncounter
        )
    }

    private func currentPersistentState(savedAt: Date) -> OrganismPersistentState {
        OrganismPersistentState(
            savedAt: savedAt,
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            field: field,
            predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState,
            reflexState: reflexState,
            signalCount: signalCount,
            lastSignalAt: lastSignalAt,
            caringEncounter: caringEncounter
        )
    }

    private func revisionFingerprint(for state: OrganismPersistentState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = (try? encoder.encode(state)) ?? Data()
        if let belief = bodySchema.providerPathBelief {
            data.append(Data("|belief:\(belief.generatedAt.timeIntervalSince1970):\(belief.estimate):\(belief.freshness):\(belief.uncertainty):\(belief.evidenceCount)".utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func restorePersistentState(
        _ state: OrganismPersistentState,
        limits: OrganismPersistenceLimits = .defaults
    ) async {
        guard configuration.enabled else { return }
        let now = dependencies.now()
        let restored = withFatigueClock(
            state.decayed(at: now, limits: limits),
            from: state.chemicalState.fatigue,
            // A restart is quiet time like any other, bounded by the same
            // 72-hour horizon the rest of the restore uses.
            elapsed: min(
                max(0, now.timeIntervalSince(state.savedAt)),
                limits.maximumDecayHours * 3_600
            )
        ).state
        wakefulnessFatigue = 0
        chemicalState = restored.chemicalState
        bodySchema = restored.bodySchema
        field = restored.field
        predictionLedger = restored.predictionLedger
        dreamRepairState = restored.dreamRepairState
        reflexState = restored.reflexState
        signalCount = restored.signalCount
        lastSignalAt = restored.lastSignalAt
        // The encounter comes back with the axis it raised: relaunching in the
        // middle of an affectionate exchange must not dose its next turn again.
        caringEncounter = restored.caringEncounter
        // FORWARD-SETTLED CONTINUITY SURVIVES THE RESTART (review c4 item 3).
        // `settleContinuity()` decays through now+6h and exports `savedAt` at that
        // future instant, so `decayed(at:)` correctly applies nothing on a
        // relaunch inside those six hours — but anchoring `lastSettledAt` at `now`
        // handed that same six-hour window back to runtime settlement, which then
        // spent it a second time. Keep the future anchor; it is the instant the
        // state has actually been decayed THROUGH, and settleElapsedTime's
        // minimum-interval guard ignores the negative elapsed values until then.
        lastSettledAt = max(now, state.savedAt)
        publishPredictedToolGroups(at: now)
    }

    public func settleContinuity() async {
        guard configuration.enabled else { return }
        let now = dependencies.now()
        settleElapsedTime(at: now)
        let state = OrganismPersistentState(
            savedAt: now,
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            field: field,
            predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState,
            reflexState: reflexState,
            signalCount: signalCount,
            lastSignalAt: lastSignalAt,
            caringEncounter: caringEncounter
        ).decayed(at: now.addingTimeInterval(6 * 3_600))
        let settledForward = withFatigueClock(
            state,
            from: chemicalState.fatigue,
            elapsed: 6 * 3_600
        )
        wakefulnessFatigue = settledForward.wakefulness
        chemicalState = settledForward.state.chemicalState
        bodySchema = state.bodySchema
        field = state.field
        predictionLedger = state.predictionLedger
        dreamRepairState = state.dreamRepairState
        reflexState = state.reflexState
        signalCount = state.signalCount
        lastSignalAt = state.lastSignalAt
        // 2026-07-21 audit fix: anchor at the instant the forward decay was
        // applied THROUGH (now + 6h), not at now — previously every
        // subsequent settleElapsedTime decayed the same 6-hour window a
        // second time as wall clock caught up (12h total decay at the 6h
        // mark). settleElapsedTime's minimum-interval guard ignores the
        // negative elapsed values this anchor produces until then.
        lastSettledAt = now.addingTimeInterval(6 * 3_600)
        publishPredictedToolGroups(at: now)
    }

    public func reviewReflexCandidate(
        id: String,
        decision: OrganismReflexReviewDecision,
        note: String? = nil,
        reviewedBy: String = "operator",
        source: String = "runtime",
        receiptID: String? = nil
    ) async -> OrganismReflexReviewApplication? {
        guard configuration.enabled else { return nil }
        settleElapsedTime(at: dependencies.now())
        guard let application = reflexState.applyingReview(
            id: id,
            decision: decision,
            reviewedAt: dependencies.now(),
            reviewedBy: reviewedBy,
            source: source,
            note: note,
            receiptID: receiptID ?? dependencies.makeUUID().uuidString,
            limits: configuration.reflexLimits
        ) else { return nil }
        reflexState = application.state
        return application
    }

    public func clearTransientState() async {
        chemicalState = .neutral
        bodySchema = .neutral
        field = .empty
        predictionLedger = .empty
        dreamRepairState = .empty
        reflexState = .empty
        signalCount = 0
        lastSignalAt = nil
        wakefulnessFatigue = 0
        // The caring lane clears with the chemistry it doses (review item 4).
        // A surviving encounter would suppress the first post-reset caring dose
        // for up to its window, and a surviving counted key would refuse the
        // same moment forever.
        caringEncounter = .empty
        countedCaringEventKeys.removeAll(keepingCapacity: false)
        countedCaringEventKeyOrder.removeAll(keepingCapacity: false)
        lastSettledAt = dependencies.now()
        publishPredictedToolGroups(at: lastSettledAt)
    }

    /// Keep a running organism alive in wall time. Persistence restore already
    /// decays from its saved timestamp; this applies the same bounded chemistry,
    /// field, and prediction settling between live reads/signals without clearing
    /// the freshly sampled body schema. The one-second floor prevents hot UI/tool
    /// reads from repeatedly rewriting state for imperceptible intervals.
    /// Fatigue's own clock (item 4, 2026-09-02). `OrganismPersistentState.decayed`
    /// relaxes fatigue with the generic quick factor (0.78^h, ≈2.8 h half-life);
    /// a tiring day has to outlive a coffee break, so every settle path replaces
    /// that one axis with `OrganismChemistry.relaxedFatigue`'s slower law. One
    /// helper, called everywhere `decayed` is, so the two can never disagree.
    /// `accruesWakefulness` is true ONLY for the live wall-clock settle. A
    /// restore, a frozen read, and the deliberate forward `settleContinuity`
    /// all relax the axis without adding hours awake: downtime is not
    /// wakefulness, a pure read must not invent it, and a forward settle is an
    /// operation on state rather than time she lived through.
    private func withFatigueClock(
        _ decayed: OrganismPersistentState,
        from before: Double,
        elapsed: TimeInterval,
        accruesWakefulness: Bool = false
    ) -> (state: OrganismPersistentState, wakefulness: Double) {
        var next = decayed
        let relaxedTotal = OrganismChemistry.relaxedFatigue(before, elapsed: elapsed)
        guard accruesWakefulness else {
            next.chemicalState.fatigue = relaxedTotal
            return (next, OrganismChemistry.relaxedFatigue(wakefulnessFatigue, elapsed: elapsed))
        }
        let awake = OrganismChemistry.wakefulness(wakefulnessFatigue, elapsed: elapsed)
        next.chemicalState.fatigue = ChemicalState.clamp(relaxedTotal + awake.gain)
        return (next, awake.share)
    }

    /// ONE CARING MOMENT, DELIVERED DIRECTLY (2026-09-11, fourth pass).
    ///
    /// The only door tenderness's caring dose comes through. The appraisal owner
    /// (`CognitiveSubstrate`) calls this as soon as its model call returns,
    /// carrying the ORIGINATING turn's timestamp and the window the moment is to
    /// be measured against. Returns what happened, because the caller keeps the
    /// short ledger of recent encounters the relay judgment is shown.
    ///
    /// THE TWO GATES, in order:
    ///   · the same MOMENT arriving twice (session + turn + kind). Two minters
    ///     for one chat message, a replay, a re-projection. This one does not
    ///     touch the encounter window at all — it is the same turn, not a second
    ///     turn of the exchange, and rolling the window on it would let one
    ///     message re-minted every twenty minutes hold an encounter open forever.
    ///   · a DIFFERENT moment inside the encounter the last one opened. It is
    ///     real and it is new, and it is still the same exchange, so it extends
    ///     the encounter rather than dosing again.
    @discardableResult
    public func admitCaringEvent(
        _ reading: OrganismCaringEvent.Reading,
        window: TimeInterval = OrganismCaringEvent.encounterWindow
    ) async -> OrganismCaringEventOutcome {
        guard configuration.enabled else { return .refused }
        settleElapsedTime(at: dependencies.now())
        let key = reading.dedupeKey
        guard !countedCaringEventKeys.contains(key) else { return .alreadyCounted }
        countedCaringEventKeys.insert(key)
        countedCaringEventKeyOrder.append(key)
        if countedCaringEventKeyOrder.count > OrganismCaringEvent.maximumRememberedKeys {
            let stale = countedCaringEventKeyOrder.removeFirst()
            countedCaringEventKeys.remove(stale)
        }
        let opens = caringEncounter.opensNewEncounter(at: reading.at, window: window)
        caringEncounter.extend(to: reading.at)
        guard opens else { return .coalesced }
        chemicalState.tenderness = OrganismChemistry.dosedByCaringEvent(chemicalState.tenderness)
        return .dosed
    }

    private func settleElapsedTime(at now: Date) {
        let elapsed = now.timeIntervalSince(lastSettledAt)
        guard elapsed >= Self.minimumRuntimeDecayInterval else { return }
        let fatigueBefore = chemicalState.fatigue
        let clocked = withFatigueClock(OrganismPersistentState(
            savedAt: lastSettledAt,
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            field: field,
            predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState,
            reflexState: reflexState,
            signalCount: signalCount,
            lastSignalAt: lastSignalAt
        ).decayed(at: now, settleBodySchema: false),
            from: fatigueBefore,
            elapsed: elapsed,
            // The one place real, lived wall time passes.
            accruesWakefulness: true)
        let settled = clocked.state
        wakefulnessFatigue = clocked.wakefulness
        chemicalState = settled.chemicalState
        bodySchema = settled.bodySchema
        field = settled.field
        predictionLedger = settled.predictionLedger
        dreamRepairState = settled.dreamRepairState
        reflexState = settled.reflexState
        signalCount = settled.signalCount
        lastSignalAt = settled.lastSignalAt
        lastSettledAt = now
        publishPredictedToolGroups(at: now)
    }

    private func publishPredictedToolGroups(at now: Date) {
        guard configuration.enabled else {
            dependencies.predictedToolGroupsSink([])
            return
        }
        dependencies.predictedToolGroupsSink(
            OrganismProspectiveAffect.predictedToolGroups(
                ledger: predictionLedger,
                at: now
            )
        )
    }

    private func currentResidualRepairOpportunity(at now: Date) -> OrganismResidualRepairOpportunity {
        OrganismResidualRepair.opportunity(
            ledger: predictionLedger,
            field: field,
            repairState: dreamRepairState,
            lastSignalAt: lastSignalAt,
            at: now,
            resourcePressure: bodySchema.resourcePressure
        )
    }
}

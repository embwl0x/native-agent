import CryptoKit
import Foundation

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
        self.configuration = configuration
        lastSettledAt = dependencies.now()
        publishPredictedToolGroups(at: lastSettledAt)
    }

    public func ingest(_ signal: SomaticSignal) async {
        guard configuration.enabled else { return }
        let ingestedAt = dependencies.now()
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
        let updated = OrganismChemistry.applying(
            signal: bounded,
            to: chemicalState,
            bodySchema: bodySchema
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
        reflexState = OrganismReflexCompiler.applying(
            signal: bounded,
            to: reflexState,
            limits: configuration.reflexLimits
        )
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
        return OrganismChemistry.projection(
            at: now,
            chemicalState: anticipated,
            bodySchema: bodySchema
        )
    }

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
        let projection = configuration.enabled
            ? OrganismChemistry.projection(
                at: now,
                chemicalState: OrganismProspectiveAffect.modulate(
                    chemicalState, ledger: predictionLedger, at: now),
                bodySchema: bodySchema
            )
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
            reflexCandidates: configuration.enabled ? reflexState.reviewCandidates() : [],
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
            ? raw.decayed(at: fixedAt, settleBodySchema: false)
            : raw
        let projection: OrganismProjection
        let snapshot: OrganismSnapshot
        if configuration.enabled {
            let anticipated = OrganismProspectiveAffect.modulate(
                frozen.chemicalState,
                ledger: frozen.predictionLedger,
                at: fixedAt
            )
            projection = OrganismChemistry.projection(
                at: fixedAt,
                chemicalState: anticipated,
                bodySchema: frozen.bodySchema
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
                reflexCandidates: frozen.reflexState.reviewCandidates(),
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
            lastSignalAt: lastSignalAt
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
            lastSignalAt: lastSignalAt
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
        let restored = state.decayed(at: now, limits: limits)
        chemicalState = restored.chemicalState
        bodySchema = restored.bodySchema
        field = restored.field
        predictionLedger = restored.predictionLedger
        dreamRepairState = restored.dreamRepairState
        reflexState = restored.reflexState
        signalCount = restored.signalCount
        lastSignalAt = restored.lastSignalAt
        lastSettledAt = now
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
            lastSignalAt: lastSignalAt
        ).decayed(at: now.addingTimeInterval(6 * 3_600))
        chemicalState = state.chemicalState
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
        source: String = "runtime"
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
            receiptID: dependencies.makeUUID().uuidString,
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
        lastSettledAt = dependencies.now()
        publishPredictedToolGroups(at: lastSettledAt)
    }

    /// Keep a running organism alive in wall time. Persistence restore already
    /// decays from its saved timestamp; this applies the same bounded chemistry,
    /// field, and prediction settling between live reads/signals without clearing
    /// the freshly sampled body schema. The one-second floor prevents hot UI/tool
    /// reads from repeatedly rewriting state for imperceptible intervals.
    private func settleElapsedTime(at now: Date) {
        let elapsed = now.timeIntervalSince(lastSettledAt)
        guard elapsed >= Self.minimumRuntimeDecayInterval else { return }
        let settled = OrganismPersistentState(
            savedAt: lastSettledAt,
            chemicalState: chemicalState,
            bodySchema: bodySchema,
            field: field,
            predictionLedger: predictionLedger,
            dreamRepairState: dreamRepairState,
            reflexState: reflexState,
            signalCount: signalCount,
            lastSignalAt: lastSignalAt
        ).decayed(at: now, settleBodySchema: false)
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

import Foundation
import PersistenceCore

public enum OrganismPredictiveBody {
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
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        limits: OrganismPredictionLimits = .defaults
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState, bodySchema: BodySchema) {
        var nextLedger = ledger
        var nextChemistry = chemicalState
        var nextBody = bodySchema

        // Item 5's mint is NOT here. A `.horizonRefresh` signal never reaches
        // this function — the kernel routes it to `applyingHorizonRefresh`,
        // which is the whole of what a calendar read is allowed to do. Ordinary
        // signals still expire passed horizon rows through the sweep below
        // (`applyExpiryTransition` owns the no-miss exception), so a horizon can
        // pass while she is working and be announced without waiting for the
        // next deadline.

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
        case .assistantSpoke:
            // Item 46 MINT. Inert unless the appraisal owner stamped an
            // expectation on this turn — the common case is no metadata and no
            // row.
            mintSemanticExpectation(signal: signal, in: &nextLedger)
        case .userSpoke:
            // Item 46 RESOLVE. The next user turn is the answer to whatever she
            // expected of the last one.
            resolveSemanticExpectations(
                signal: signal,
                ledger: &nextLedger,
                chemicalState: &nextChemistry
            )
        case .correctionReceived, .appWake, .appSleep:
            break
        case .horizonRefresh:
            // Already handled: `applyHorizonSources` runs at the top of this
            // function, before the expiry sweep, for exactly this signal. There
            // is nothing left for the kind switch to do.
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
            let isMiss = applyExpiryTransition(to: &prediction, at: date)
            ledger.predictions[id] = prediction
            ledger.expiredCount += 1
            guard isMiss else { continue }
            recordOutcome(.expired, kind: prediction.kind, at: date, ledger: &ledger)
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

    /// THE expiry transition on a prediction ROW. One function, two callers:
    /// this file's live sweep and `OrganismPersistentState.decayed(at:)`'s
    /// restart/idle sweep. They had drifted — the restore path flipped `status`
    /// and `lastUpdatedAt` and stopped, so an expectation that ran out across a
    /// restart kept the confidence and uncertainty of a live pending row, while
    /// the same expectation running out with the app awake was marked down.
    /// Same event, two different bodies, decided by whether she happened to be
    /// running.
    ///
    /// Returns whether this expiry is a MISS — evidence she was wrong, to be
    /// counted and punished by the caller. Every non-horizon expiry is; no
    /// horizon expiry is (Friday arriving with nothing on it means she was
    /// waiting, not wrong), which is the one deliberate exception and is stated
    /// here rather than duplicated at both call sites.
    ///
    /// The LEDGER-level consequences deliberately stay with the callers: the
    /// live sweep stamps `lastViolationAt` and applies the chemistry, and the
    /// restore sweep does neither, because a miss discovered hours later must
    /// not arm a 20-minute violation shadow dated now or move a body that has
    /// already decayed through the gap.
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
            existing.evidenceCount += 1
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

    private static func satisfy(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let existing = ledger.predictions[id]
        if let existing {
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            // A replay of the same terminal edge is not new evidence. Keep
            // equal-time pending→terminal transitions valid: some lifecycle
            // owners legitimately stamp both phases from one clock sample.
            if existing.status == .satisfied,
               signal.occurredAt == existing.lastUpdatedAt { return }
        }
        var prediction = existing ?? terminalPrediction(kind, signal: signal)
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
            recordOutcome(.satisfied, kind: kind, at: signal.occurredAt, ledger: &ledger)
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
        let existing = ledger.predictions[id]
        if let existing {
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            if existing.status == .violated,
               signal.occurredAt == existing.lastUpdatedAt { return }
        }
        var prediction = existing ?? terminalPrediction(kind, signal: signal)
        if prediction.status != .violated {
            ledger.violatedCount += 1
            recordOutcome(.violated, kind: kind, at: signal.occurredAt, ledger: &ledger)
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
            id: "terminal:\(kind.rawValue):\(OrganismToken.canonicalToken(signal.sourceOrgan)):\(Int(signal.occurredAt.timeIntervalSince1970))",
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

    // MARK: - Item 46: the semantic lane

    /// Open an expectation about how the turn she just finished will land.
    /// Bounded four ways: the label AND the scope must be present and legible,
    /// at most `maximumPendingPerSession` may be open for that session, and a
    /// replayed signal cannot open the same row twice (the id folds in the turn
    /// and its own second).
    private static func mintSemanticExpectation(
        signal: SomaticSignal,
        in ledger: inout OrganismPredictionLedger
    ) {
        guard let rawLabel = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.concernField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let label = OrganismToken.canonicalToken(rawLabel)
        guard label != "unknown" else { return }
        // Review fix 2: an unscoped expectation could only ever be resolved by
        // settling the whole ledger, which is the defect. No scope, no row.
        guard let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let id = semanticExpectationID(signal: signal, label: label, scope: scope)
        guard ledger.predictions[id] == nil else { return }

        // Review fix 5: the cap is per session and evicts the OLDEST pending row
        // there. The newest expectation is the one the next turn is about;
        // dropping it discarded the only row that could still resolve.
        let sessionPending = ledger.predictions.values
            .filter {
                $0.kind == .semanticExpectation && $0.status == .pending
                    && $0.semanticScope?.sessionID == scope.sessionID
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        if sessionPending.count >= OrganismSemanticExpectation.maximumPendingPerSession {
            let overflow = sessionPending.count
                - OrganismSemanticExpectation.maximumPendingPerSession + 1
            for stale in sessionPending.prefix(overflow) {
                // Evicted, not expired: she stopped holding it, which is not the
                // same as having been wrong about it. No outcome is recorded and
                // no violation effect fires.
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }

        let i = OrganismBodyConfidence.clamp(signal.intensity)
        ledger.predictions[id] = OrganismPrediction(
            id: id,
            kind: .semanticExpectation,
            sourceOrgan: OrganismToken.canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt.addingTimeInterval(OrganismSemanticExpectation.horizon),
            confidence: 0.5 + 0.3 * i,
            uncertainty: 0.5 - 0.2 * i,
            lastUpdatedAt: signal.occurredAt,
            semanticScope: scope
        )
    }

    /// Settle the semantic expectations THIS user turn actually answers.
    ///
    /// Review fix 2: scope decides, not "everything pending". The reaction
    /// carries the session and the completion turn it is a verdict on, and only
    /// rows minted under that exact pair are settled — a reply in one
    /// conversation can no longer resolve, or punish, an expectation formed in
    /// another. A turn is also never the reaction to itself (the same guard the
    /// substrate's completion reconsolidation makes).
    private static func resolveSemanticExpectations(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        guard let rawReaction = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.reactionField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) else { return }
        guard let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) else { return }
        let clean = rawReaction.lowercased()
        // Fail toward "he did not push back". An unrecognised label is an absent
        // reading, and an absent reading must never mint the punishing outcome.
        let reaction = [
            OrganismSemanticExpectation.pushbackReaction,
            OrganismSemanticExpectation.confirmedReaction,
        ].contains(clean) ? clean : OrganismSemanticExpectation.neutralReaction
        let violated = reaction == OrganismSemanticExpectation.pushbackReaction
        let intensity = violated
            ? OrganismBodyConfidence.clamp(max(0.2, signal.intensity))
            : OrganismSemanticExpectation.satisfiedIntensity(
                for: reaction, signalIntensity: signal.intensity
            )
        for id in ledger.predictions.keys.sorted() {
            guard let prediction = ledger.predictions[id],
                  prediction.kind == .semanticExpectation,
                  prediction.status == .pending,
                  prediction.semanticScope == scope,
                  signal.occurredAt > prediction.createdAt,
                  signal.occurredAt >= prediction.lastUpdatedAt else { continue }
            settleSemanticExpectation(
                prediction,
                satisfied: !violated,
                at: signal.occurredAt,
                intensity: intensity,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
    }

    /// The SAME resolution arithmetic `satisfy`/`violate` apply, addressed by
    /// row id instead of by signal correlation — a semantic expectation is
    /// answered by "the next thing he said", which carries no correlation id.
    /// Every downstream consequence (outcome counts, lastViolationAt, the felt
    /// relief/disappointment diff, chemistry) is the shared machinery.
    private static func settleSemanticExpectation(
        _ prediction: OrganismPrediction,
        satisfied: Bool,
        at date: Date,
        intensity: Double,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        var row = prediction
        let i = OrganismBodyConfidence.clamp(intensity)
        // Measure the bracing BEFORE the row mutates, exactly as `satisfy` does.
        let bracing = satisfied
            ? min(1, OrganismProspectiveAffect.predictionBracingContribution(
                    row, ledger: ledger, at: date
                  ).bracing + OrganismProspectiveAffect.violationShadow(ledger, at: date))
            : 0
        if satisfied {
            ledger.satisfiedCount += 1
            recordOutcome(.satisfied, kind: .semanticExpectation, at: date, ledger: &ledger)
            row.status = .satisfied
            row.confidence = OrganismBodyConfidence.clamp(row.confidence + 0.18 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty - 0.16 * i)
        } else {
            ledger.violatedCount += 1
            recordOutcome(.violated, kind: .semanticExpectation, at: date, ledger: &ledger)
            row.status = .violated
            row.confidence = OrganismBodyConfidence.clamp(row.confidence - 0.20 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty + 0.22 * i)
            ledger.lastViolationAt = date
        }
        row.evidenceCount += 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        if satisfied {
            applySatisfiedEffect(
                kind: .semanticExpectation, intensity: i, bracing: bracing,
                ledger: &ledger, chemicalState: &chemicalState
            )
        } else {
            applyViolationEffect(
                kind: .semanticExpectation, intensity: i,
                ledger: &ledger, chemicalState: &chemicalState
            )
        }
    }

    /// Deterministic and collision-proof: organ, scope, concern label, and the
    /// turn's own second. Public so the appraisal owner's tests can address a
    /// row they minted without reaching into the ledger's private keying.
    public static func semanticExpectationID(
        signal: SomaticSignal,
        label: String,
        scope: OrganismSemanticScope
    ) -> String {
        [
            OrganismSemanticExpectation.idPrefix,
            OrganismToken.canonicalToken(signal.sourceOrgan),
            OrganismToken.canonicalToken(scope.sessionID),
            OrganismToken.canonicalToken(scope.turnID),
            OrganismToken.canonicalToken(label),
            String(Int(signal.occurredAt.timeIntervalSince1970)),
        ].joined(separator: ":")
    }

    /// Relief gain: a satisfied outcome the body was fully braced for
    /// releases up to 2.5× the calm-path amount — the exhale is sized to the
    /// held breath (round 3 Wave A; bracing 0 → multiplier exactly 1).
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
            // Being wrong about the WORK is the learning this whole item exists
            // for. It rides the same axes a tool violation does — she gets more
            // careful about the next claim and less sure of herself — but does
            // not raise urgency: a person disagreeing is not a deadline.
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

    private static func enforcingCapacity(
        _ ledger: OrganismPredictionLedger,
        limits: OrganismPredictionLimits
    ) -> OrganismPredictionLedger {
        guard ledger.predictions.count > limits.maximumPredictions else { return ledger }
        var next = ledger
        let keep = Set(OrganismPredictionRetention.bounded(
            Array(ledger.predictions.values), maximum: limits.maximumPredictions
        ).map(\.id))
        next.predictions = ledger.predictions.filter { keep.contains($0.key) }
        return next
    }

    /// Internal rather than private: the restart/idle sweep in
    /// `OrganismPersistentState.decayed(at:)` finds expiries the live sweep
    /// never sees, and both paths must stamp identical evidence.
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
            count.satisfied += 1
            weights.satisfied += 1
        case .violated:
            count.violated += 1
            weights.violated += 1
        case .expired:
            count.expired += 1
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

/// Keeps every pending expectation first, then retains recent terminal
/// evidence fairly across capability kinds. Status never decides which
/// terminal outcomes survive: prioritizing violations made the reservoir look
/// like a failure-rate sample even when lifetime outcomes were overwhelmingly
/// successful.
enum OrganismPredictionRetention {
    static func bounded(
        _ predictions: [OrganismPrediction],
        maximum: Int
    ) -> [OrganismPrediction] {
        guard maximum > 0 else { return [] }
        // Item 5 (2026-09-02): HORIZON rows rank after every other pending row.
        // They are pending for DAYS by construction, and `recentFirst` sorts by
        // `lastUpdatedAt` — so a register refreshed at the residual deadline
        // looked like the freshest thing in the ledger and could evict live
        // tool, provider and approval expectations at the 96 cap. Her calendar
        // must never crowd out her hands. The horizon family has its own cap
        // (`OrganismHorizonRegister.maximumOpen`, enforced at the mint), so this
        // ordering is the only place the operational cap needs to know about it.
        let allPending = predictions.filter { $0.status == .pending }
        let pending = allPending.filter { $0.horizon == nil }.sorted(by: recentFirst)
            + allPending.filter { $0.horizon != nil }.sorted(by: recentFirst)
        if pending.count >= maximum { return Array(pending.prefix(maximum)) }

        var result = pending
        var buckets = Dictionary(grouping: predictions.filter { $0.status != .pending }, by: \.kind)
            .mapValues { $0.sorted(by: recentFirst) }
        let kinds = OrganismPredictionKind.allCases
        while result.count < maximum {
            var appended = false
            for kind in kinds where result.count < maximum {
                guard var bucket = buckets[kind], !bucket.isEmpty else { continue }
                result.append(bucket.removeFirst())
                buckets[kind] = bucket
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

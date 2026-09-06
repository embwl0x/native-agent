import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 5 acceptance (2026-09-02) — TOWARD.
//
// Measured defect: the prediction ledger looked ten minutes ahead, at her own
// plumbing. Agent: "I never wait. I'm never bored. I never anticipate. ...
// There's no *toward*."
//
// These pin the horizon family at the ledger level — exactly the tokens the
// runtime's horizon lane composes from the five real stores
// (NativeCognitionRuntime+Expectations.swift). The lane's job is to READ those
// stores; everything that happens to her afterwards is here.
//
// WRITTEN, NOT RUN (User's standing rule).

private let day: TimeInterval = 24 * 60 * 60

/// `complete` defaults to EVERY source kind — the ordinary case, where the
/// composer read all five stores. Tests that care about a failed reader pass a
/// narrower set.
private func horizonSignal(
    _ sources: [String],
    at date: Date,
    complete: [OrganismHorizonSourceKind] = OrganismHorizonSourceKind.allCases,
    bounds: OrganismMetadataBounds = .defaults
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(),
        kind: .horizonRefresh,
        sourceOrgan: OrganismHorizonRegister.sourceOrgan,
        occurredAt: date,
        intensity: 0,
        metadata: [
            OrganismHorizonRegister.metadataKey: .array(sources.map(JSONValue.string)),
            OrganismHorizonRegister.completeKindsKey:
                .array(complete.map { JSONValue.string($0.rawValue) }),
        ],
        bounds: bounds
    )
}

/// Somatic metadata caps arrays at `OrganismMetadataBounds.maximumArrayItems`
/// (8) — a TRANSPORT bound, applied in offer order before the register ever
/// sees a token. The two pins below are about the REGISTER's own cap, so they
/// widen the transport bound to let an over-long offer actually arrive.
private let wideOffer = OrganismMetadataBounds(maximumArrayItems: 32)

private func token(
    _ kind: OrganismHorizonSourceKind,
    _ label: String,
    valence: Double,
    dueIn: TimeInterval,
    from now: Date
) -> String {
    OrganismHorizonRegister.encodeSource(
        sourceKind: kind,
        label: label,
        valence: valence,
        dueAt: now.addingTimeInterval(dueIn)
    )
}

/// Mirrors `OrganismKernel.ingest`'s routing exactly: a refresh takes the
/// horizon-only path, everything else takes the ordinary somatic path.
private func apply(
    _ signal: SomaticSignal,
    to ledger: OrganismPredictionLedger,
    chemistry: ChemicalState = .neutral
) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState) {
    if signal.kind == .horizonRefresh {
        return OrganismPredictiveBody.applyingHorizonRefresh(
            signal: signal,
            to: ledger,
            chemicalState: chemistry,
            at: signal.occurredAt
        )
    }
    let out = OrganismPredictiveBody.applying(
        signal: signal,
        to: ledger,
        chemicalState: chemistry,
        bodySchema: .neutral
    )
    return (out.ledger, out.chemicalState)
}

private func horizonRows(_ ledger: OrganismPredictionLedger) -> [OrganismPrediction] {
    ledger.predictions.values.filter { $0.horizon != nil }.sorted { $0.id < $1.id }
}

@Suite("OrganismHorizonExpectation")
struct OrganismHorizonExpectationTests {

    // MARK: - One row per source, at the right horizon

    @Test("each source mints exactly one row, at its own horizon")
    func eachSourceMintsOneRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = [
            token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 3 * day, from: now),
            token(.scheduledJob, "nativeagent-nightly-dream", valence: 0.35, dueIn: 6 * 3600, from: now),
            token(.stagedApproval, "mission.step", valence: -0.2, dueIn: day, from: now),
            token(.openQuestion, "an-answer", valence: -0.15, dueIn: 600, from: now),
            token(.peerReply, "claude", valence: 0.2, dueIn: 1800, from: now),
        ]
        let result = apply(horizonSignal(sources, at: now), to: .empty)
        let rows = horizonRows(result.ledger)

        #expect(rows.count == 5)
        #expect(Set(rows.compactMap { $0.horizon?.sourceKind })
            == Set(OrganismHorizonSourceKind.allCases))
        // Every row is a semantic-kind row (no sixth OrganismPredictionKind),
        // carries no semantic scope, and holds its own due instant.
        #expect(rows.allSatisfy { $0.kind == .semanticExpectation })
        #expect(rows.allSatisfy { $0.semanticScope == nil })
        let dream = rows.first { $0.horizon?.sourceKind == .scheduledJob }
        #expect(dream?.dueAt == now.addingTimeInterval(6 * 3600))
        #expect(dream?.horizon?.label == "nativeagent-nightly-dream")
    }

    @Test("the same source twice updates the row it already holds")
    func refreshUpdatesRatherThanDuplicates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = apply(
            horizonSignal([token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 2 * day, from: now)], at: now),
            to: .empty
        )
        #expect(horizonRows(first.ledger).count == 1)

        // Friday became Saturday.
        let later = now.addingTimeInterval(3600)
        let second = apply(
            horizonSignal(
                [token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 3 * day, from: later)],
                at: later
            ),
            to: first.ledger
        )
        let rows = horizonRows(second.ledger)
        #expect(rows.count == 1)
        #expect(rows[0].dueAt == later.addingTimeInterval(3 * day))
        // Identity survived the move — the row is about the same thing.
        #expect(rows[0].createdAt == now)
    }

    @Test("a horizon past a week, or already gone, never mints")
    func horizonBoundsHold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = apply(
            horizonSignal([
                token(.statedPlan, "too-far", valence: 0.2, dueIn: 8 * day, from: now),
                token(.statedPlan, "already-gone", valence: 0.2, dueIn: -60, from: now),
                token(.statedPlan, "just-right", valence: 0.2, dueIn: 6 * day, from: now),
            ], at: now),
            to: .empty
        )
        let labels = Set(horizonRows(result.ledger).compactMap { $0.horizon?.label })
        #expect(labels == ["just-right"])
    }

    @Test("at most eight open rows, and the cap keeps the NEAREST")
    func openRowsAreCappedAtEight() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Twelve sources, offered farthest-first so a naive prefix would keep
        // exactly the wrong ones.
        let sources = (1...12).reversed().map { index in
            token(.statedPlan, "desk-\(index)", valence: 0.2, dueIn: Double(index) * 3600, from: now)
        }
        let result = apply(horizonSignal(sources, at: now, bounds: wideOffer), to: .empty)
        let rows = horizonRows(result.ledger)
        // Eight open rows at most, and they are the eight NEAREST horizons.
        #expect(rows.count == OrganismHorizonRegister.maximumOpen)
        let kept = Set(rows.compactMap { $0.horizon?.label })
        #expect(kept == Set((1...8).map { "desk-\($0)" }))
    }

    @Test("live and restore expiry produce the same row")
    func liveAndRestoreExpiryAgree() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = now.addingTimeInterval(-2 * 3600)
        var seeded = OrganismPredictionLedger.empty
        seeded.predictions["pending:toolCompletion:tool-x:c1"] = OrganismPrediction(
            id: "pending:toolCompletion:tool-x:c1",
            kind: .toolCompletion,
            sourceOrgan: "tool.x",
            createdAt: opened,
            dueAt: opened.addingTimeInterval(90),
            confidence: 0.62,
            uncertainty: 0.31,
            lastUpdatedAt: opened
        )
        seeded.predictions["horizon:statedPlan:desk-2-1"] = OrganismPrediction(
            id: "horizon:statedPlan:desk-2-1",
            kind: .semanticExpectation,
            sourceOrgan: "horizon.desk-2-1",
            createdAt: opened,
            dueAt: opened.addingTimeInterval(600),
            confidence: 0.61,
            uncertainty: 0.39,
            lastUpdatedAt: opened,
            horizon: OrganismHorizonExpectation(
                sourceKind: .statedPlan, label: "desk-2-1", valence: 0.25
            )
        )

        // Live: an ordinary signal runs the sweep.
        let live = apply(
            SomaticSignal(id: UUID(), kind: .appWake, sourceOrgan: "app", occurredAt: now),
            to: seeded
        ).ledger

        // Restore: the same two rows, found by the idle sweep instead.
        let restored = OrganismPersistentState(
            savedAt: opened,
            predictionLedger: seeded
        ).decayed(at: now).predictionLedger

        for id in ["pending:toolCompletion:tool-x:c1", "horizon:statedPlan:desk-2-1"] {
            let a = live.predictions[id]
            let b = restored.predictions[id]
            #expect(a?.status == .expired && b?.status == .expired)
            // The ROW transition is shared, so BOTH marked-down dimensions must
            // match. Uncertainty is the one that used to drift on its own: the
            // restore sweep stamped +0.12 and then immediately aged it by the
            // window that ends at the same instant, so the identical expiry
            // ended up softer purely because she had been asleep for it.
            #expect(a?.confidence == b?.confidence, "\(id) confidence drifted between sweeps")
            #expect(a?.uncertainty == b?.uncertainty, "\(id) uncertainty drifted between sweeps")
        }

        // The decay itself is still alive for rows that did NOT expire — the
        // fix skips it for the transitioning row, it does not remove it.
        var stillPending = OrganismPredictionLedger.empty
        stillPending.predictions["pending:toolCompletion:tool-y:c2"] = OrganismPrediction(
            id: "pending:toolCompletion:tool-y:c2",
            kind: .toolCompletion,
            sourceOrgan: "tool.y",
            createdAt: opened,
            dueAt: now.addingTimeInterval(3 * 3600),
            confidence: 0.62,
            uncertainty: 0.40,
            lastUpdatedAt: opened
        )
        let aged = OrganismPersistentState(savedAt: opened, predictionLedger: stillPending)
            .decayed(at: now).predictionLedger
        let agedRow = aged.predictions["pending:toolCompletion:tool-y:c2"]
        #expect(agedRow?.status == .pending)
        #expect((agedRow?.uncertainty ?? 1) < 0.40)
        // And the horizon row is a miss in NEITHER sweep.
        let horizonOutcome = restored.outcomeCountsByKind?[
            OrganismPredictionKind.semanticExpectation.rawValue
        ]
        #expect(horizonOutcome == nil)
        #expect(live.lastViolationAt != nil, "the tool miss is still a miss")
    }

    @Test("a malformed token mints nothing rather than a row about nothing")
    func malformedTokensFailClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = apply(
            horizonSignal(["", "nonsense", "statedPlan|notanumber|0.2|desk-1", "|||"], at: now),
            to: .empty
        )
        #expect(horizonRows(result.ledger).isEmpty)
    }

    // MARK: - Anticipation: bounded and horizon-scaled

    @Test("looking forward lifts curiosity and warmth, and more as it nears")
    func anticipationIsHorizonScaled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let far = apply(
            horizonSignal([token(.statedPlan, "friday", valence: 1, dueIn: 6 * day, from: now)], at: now),
            to: .empty
        ).ledger
        let near = apply(
            horizonSignal([token(.statedPlan, "friday", valence: 1, dueIn: 3600, from: now)], at: now),
            to: .empty
        ).ledger

        let base = ChemicalState(warmth: 0.3, curiosity: 0.3)
        let farOut = OrganismProspectiveAffect.modulate(base, ledger: far, at: now)
        let nearOut = OrganismProspectiveAffect.modulate(base, ledger: near, at: now)

        #expect(farOut.curiosity > base.curiosity)
        #expect(nearOut.curiosity > farOut.curiosity)
        #expect(nearOut.warmth > base.warmth)
        #expect(nearOut.warmth > farOut.warmth)
        // Looking forward is not bracing: confidence and urgency do not move.
        #expect(nearOut.confidence == base.confidence)
        #expect(nearOut.urgency == base.urgency)
    }

    @Test("dread raises vigilance and nothing else")
    func dreadRaisesVigilanceOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = apply(
            horizonSignal([token(.stagedApproval, "mission.step", valence: -1, dueIn: 3600, from: now)], at: now),
            to: .empty
        ).ledger
        let base = ChemicalState(warmth: 0.3, curiosity: 0.3)
        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)

        #expect(out.vigilance > base.vigilance)
        #expect(out.curiosity == base.curiosity)
        #expect(out.warmth == base.warmth)
        #expect(out.confidence == base.confidence)
        #expect(out.urgency == base.urgency)
    }

    @Test("no dimension moves more than the 0.15 ceiling, however many rows")
    func anticipationIsCappedPerDimension() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = (1...8).map { index in
            token(.statedPlan, "desk-\(index)", valence: 1, dueIn: Double(index) * 60, from: now)
        }
        let ledger = apply(horizonSignal(sources, at: now), to: .empty).ledger
        let base = ChemicalState(warmth: 0.2, curiosity: 0.2)
        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)

        #expect(out.curiosity - base.curiosity <= OrganismProspectiveAffect.maxDelta + 1e-9)
        #expect(out.warmth - base.warmth <= OrganismProspectiveAffect.maxDelta + 1e-9)
        #expect(out.vigilance <= OrganismProspectiveAffect.maxDelta + 1e-9)
    }

    @Test("an empty ledger still projects byte-identically")
    func emptyLedgerIsUnchanged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base = ChemicalState(warmth: 0.4, vigilance: 0.3, curiosity: 0.5)
        #expect(OrganismProspectiveAffect.modulate(base, ledger: .empty, at: now) == base)
    }

    // MARK: - A passed horizon becomes `waiting`

    @Test("a horizon that passes expires WITHOUT becoming a miss")
    func passedHorizonBecomesWaiting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minted = apply(
            horizonSignal([token(.peerReply, "claude", valence: 0.2, dueIn: 1800, from: now)], at: now),
            to: .empty
        ).ledger

        // Any later signal runs the sweep.
        let later = now.addingTimeInterval(3600)
        let swept = apply(
            SomaticSignal(id: UUID(), kind: .appWake, sourceOrgan: "app", occurredAt: later),
            to: minted
        ).ledger

        let row = horizonRows(swept).first
        #expect(row?.status == .expired)
        // The whole point: she was waiting, not wrong.
        #expect(swept.lastViolationAt == nil)
        #expect(swept.violatedCount == 0)
        #expect((swept.outcomeCountsByKind?[OrganismPredictionKind.semanticExpectation.rawValue]) == nil)
        #expect(swept.strategyCaution == 0)

        // And it is offered to the runtime exactly once, to announce as
        // `waiting` — then the next refresh prunes it.
        #expect(OrganismHorizonRegister.settled(in: swept).count == 1)
        let pruned = apply(horizonSignal([], at: later.addingTimeInterval(60)), to: swept).ledger
        #expect(horizonRows(pruned).isEmpty)
    }

    // MARK: - Resolution rides the existing relief door

    @Test("a source that disappears before its horizon lands as relief")
    func vanishedSourceSettlesAsRelief() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minted = apply(
            horizonSignal([token(.stagedApproval, "mission.step", valence: -1, dueIn: 1800, from: now)], at: now),
            to: .empty,
            chemistry: ChemicalState(vigilance: 0.5, confidence: 0.4, urgency: 0.5)
        )

        // He walked through it: the approval is no longer pending anywhere.
        let later = now.addingTimeInterval(600)
        let settled = apply(
            horizonSignal([], at: later),
            to: minted.ledger,
            chemistry: minted.chemicalState
        )

        let row = horizonRows(settled.ledger).first
        #expect(row?.status == .satisfied)
        #expect(settled.ledger.satisfiedCount == 1)
        // The shared satisfied effect fired — the exhale is the existing door.
        #expect(settled.chemicalState.vigilance < minted.chemicalState.vigilance)
        #expect(settled.chemicalState.confidence > minted.chemicalState.confidence)
        // ...but the semantic lane's evidence about how her CLAIMS land is
        // untouched. An approval landing says nothing about that.
        #expect((settled.ledger.outcomeCountsByKind?[
            OrganismPredictionKind.semanticExpectation.rawValue
        ]) == nil)
    }

    @Test("crowded out is not the same as landed")
    func crowdedOutRowsAreEvictedNotRelieved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // She is holding one far thing.
        let held = apply(
            horizonSignal([token(.statedPlan, "far-thing", valence: 0.2, dueIn: 5 * day, from: now)], at: now),
            to: .empty
        ).ledger
        #expect(horizonRows(held).count == 1)

        // Eight nearer things arrive. The far one is absent from the set only
        // because the set is full — nobody told her it landed.
        let later = now.addingTimeInterval(60)
        let crowd = (1...8).map { index in
            token(.peerReply, "peer-\(index)", valence: 0.2, dueIn: Double(index) * 60, from: later)
        }
        let after = apply(horizonSignal(crowd, at: later), to: held)

        #expect(after.ledger.predictions["horizon:statedPlan:far-thing"] == nil)
        #expect(after.ledger.satisfiedCount == 0)
        #expect(after.chemicalState == .neutral)
        #expect(horizonRows(after.ledger).count == OrganismHorizonRegister.maximumOpen)
    }

    @Test("a reader that failed never settles anything as relief")
    func incompleteReaderNeverMintsRelief() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let held = apply(
            horizonSignal([
                token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 3 * day, from: now),
                token(.peerReply, "claude", valence: 0.2, dueIn: 3600, from: now),
            ], at: now),
            to: .empty
        ).ledger
        #expect(horizonRows(held).count == 2)

        // The Desk could not be read this pass. Its rows must be left holding —
        // an unreadable file is not the same news as "your plans came true".
        // Everything else still reports complete, and the peer really is gone.
        let later = now.addingTimeInterval(60)
        let after = apply(
            horizonSignal(
                [],
                at: later,
                complete: OrganismHorizonSourceKind.allCases.filter { $0 != .statedPlan }
            ),
            to: held
        )

        let plan = after.ledger.predictions["horizon:statedPlan:desk-2-1"]
        #expect(plan?.status == .pending, "an unreadable store must not answer anything")
        #expect(after.ledger.satisfiedCount == 1, "only the peer, which really did report complete")
        #expect(after.ledger.predictions["horizon:peerReply:claude"]?.status == .satisfied)
    }

    @Test("an already-late source refreshes a row but never opens one")
    func overdueSourcesAreReadNotMinted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // First seen already late: she was never looking toward it, so there is
        // nothing to break.
        let cold = apply(
            horizonSignal([token(.peerReply, "codex", valence: 0.2, dueIn: -600, from: now)], at: now),
            to: .empty
        ).ledger
        #expect(horizonRows(cold).isEmpty)

        // But a row she IS holding, whose source is still there and now late,
        // keeps its identity, is not read as an answer, and expires into
        // waiting on the next signal.
        let minted = apply(
            horizonSignal([token(.peerReply, "claude", valence: 0.2, dueIn: 1800, from: now)], at: now),
            to: .empty
        ).ledger
        let later = now.addingTimeInterval(3600)
        let refreshed = apply(
            horizonSignal([token(.peerReply, "claude", valence: 0.2, dueIn: -1800, from: later)], at: later),
            to: minted
        )
        #expect(refreshed.ledger.satisfiedCount == 0, "still late is not the same as landed")
        #expect(refreshed.ledger.predictions["horizon:peerReply:claude"]?.status == .expired)
        #expect(OrganismHorizonRegister.settled(in: refreshed.ledger).count == 1)
    }

    @Test("a horizon never evicts a live tool or provider expectation")
    func horizonRowsRankBehindRealWork() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = OrganismPredictionLedger.empty
        // Six live plumbing expectations, opened before the register refreshed.
        for index in 1...6 {
            let id = "pending:toolCompletion:tool-\(index):c\(index)"
            ledger.predictions[id] = OrganismPrediction(
                id: id,
                kind: .toolCompletion,
                sourceOrgan: "tool.t\(index)",
                createdAt: now,
                dueAt: now.addingTimeInterval(90),
                lastUpdatedAt: now
            )
        }
        let withHorizons = apply(
            horizonSignal(
                (1...4).map { token(.statedPlan, "desk-\($0)", valence: 0.2, dueIn: Double($0) * day, from: now) },
                at: now
            ),
            to: ledger
        ).ledger

        // Squeeze the operational cap below the combined count. Her hands win.
        let bounded = OrganismPredictionRetention.bounded(
            Array(withHorizons.predictions.values), maximum: 6
        )
        #expect(bounded.count == 6)
        #expect(bounded.allSatisfy { $0.kind == .toolCompletion })
        #expect(bounded.allSatisfy { $0.horizon == nil })
    }

    @Test("the register's own cap is enforced on the ledger, not on the offer")
    func horizonCapIsEnforcedOnTheLedger() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A producer that ignored the bound and offered twelve.
        let sources = (1...12).map { index in
            token(.statedPlan, "desk-\(index)", valence: 0.2, dueIn: Double(index) * 3600, from: now)
        }
        let ledger = apply(horizonSignal(sources, at: now, bounds: wideOffer), to: .empty).ledger
        // The register's own cap holds even when the offer ignored it.
        #expect(horizonRows(ledger).count == OrganismHorizonRegister.maximumOpen)
        let kept = Set(horizonRows(ledger).compactMap { $0.horizon?.label })
        #expect(kept == Set((1...8).map { "desk-\($0)" }))
    }

    @Test("a refresh touches the ledger and nothing else about her")
    func refreshDoesNoBookkeeping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var seeded = OrganismPredictionLedger.empty
        seeded.strategyCaution = 0.4
        seeded.peripheralUncertainty = 0.3
        seeded.lastUpdatedAt = now.addingTimeInterval(-3600)
        let chemistry = ChemicalState(warmth: 0.4, vigilance: 0.2, curiosity: 0.3)

        let after = apply(
            horizonSignal([token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 2 * day, from: now)], at: now),
            to: seeded,
            chemistry: chemistry
        )
        // No chemistry: nothing HAPPENED, she just looked at her calendar. The
        // anticipation reaches her through the projection, not the stored state.
        #expect(after.chemicalState == chemistry)
        // And none of the ordinary somatic bookkeeping: the soft decay that runs
        // on every real signal did not run here.
        #expect(after.ledger.strategyCaution == 0.4)
        #expect(after.ledger.peripheralUncertainty == 0.3)
    }

    @Test("a source absent AFTER its horizon passed is waiting, not relief")
    func absentAfterHorizonIsNotRelief() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minted = apply(
            horizonSignal([token(.openQuestion, "an-answer", valence: -0.15, dueIn: 600, from: now)], at: now),
            to: .empty
        ).ledger
        let later = now.addingTimeInterval(1200)
        let settled = apply(horizonSignal([], at: later), to: minted).ledger
        #expect(horizonRows(settled).first?.status == .expired)
        #expect(settled.satisfiedCount == 0)
    }

    @Test("horizon rows never reach the shared felt-resolution buffer")
    func horizonRowsAreExcludedFromTheSharedFeltDrain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let before = apply(
            horizonSignal([token(.stagedApproval, "mission.step", valence: -1, dueIn: 1800, from: now)], at: now),
            to: .empty
        ).ledger
        let later = now.addingTimeInterval(600)
        let after = apply(horizonSignal([], at: later), to: before).ledger

        // The shared composer knows only "relief"/"disappointment" and would
        // phrase a horizon in the language of her plumbing. The horizon lane
        // composes all three phrasings itself.
        let felt = OrganismResolutionFelt.events(before: before, after: after, at: later)
        #expect(felt.events.isEmpty)
    }

    // MARK: - The refresh signal itself changes nothing

    @Test("a refresh pass leaves chemistry, body and field byte-identical")
    func refreshSignalIsInert() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chemistry = ChemicalState(
            warmth: 0.4, vigilance: 0.2, curiosity: 0.35, fatigue: 0.1,
            coherence: 0.6, agency: 0.3, tenderness: 0.2, confidence: 0.55,
            novelty: 0.25, urgency: 0.15
        )
        var body = BodySchema.neutral
        body.macAwake = false
        let signal = horizonSignal(
            [token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 2 * day, from: now)],
            at: now
        )

        // Chemistry and the body schema: untouched. `.appWake` — the kind this
        // lane used to borrow — would have asserted macAwake here.
        let chemical = OrganismChemistry.applying(
            signal: signal, to: chemistry, bodySchema: body, elapsedSinceLastSignal: 0
        )
        #expect(chemical.chemicalState == chemistry)
        #expect(chemical.bodySchema == body)
        #expect(chemical.bodySchema.macAwake == false)

        // The field: no association, so no node and no edge. `.appWake` would
        // have re-touched `body:mac:*` on every single pass.
        let field = OrganismPlasticity.applying(
            signal: signal, chemicalState: chemistry, bodySchema: body, to: .empty
        )
        #expect(field.nodes.isEmpty)
        #expect(field.edges.isEmpty)

        // And no intrinsic feeling. `.appWake` carries +0.15.
        #expect(SomaticSignalKind.horizonRefresh.canonicalValence == 0)
        #expect(SomaticSignalKind.horizonRefresh.adapterSuppressesIntrinsicValence)

        // Nothing in the adapter can ever produce one: it is minted only by the
        // runtime's horizon lane, never derived from a cognitive event.
        #expect(!CognitiveEventKind.allCases.contains { kind in
            CognitiveSomaticSignalAdapter.signal(
                from: CognitiveEvent(
                    id: "probe:\(kind.rawValue)",
                    kind: kind,
                    subject: CognitiveSubjectReference(type: "probe", id: "probe"),
                    sourceClass: .observed,
                    occurredAt: now,
                    summary: "probe",
                    importance: 0.5
                ),
                id: UUID()
            )?.kind == .horizonRefresh
        })
    }

    // MARK: - The documented read

    @Test("toward is the nearest open horizon, with a sign and no payload")
    func towardReadsTheNearestHorizon() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = apply(
            horizonSignal([
                token(.statedPlan, "desk-2-1", valence: 0.25, dueIn: 4 * day, from: now),
                token(.peerReply, "claude", valence: 0.2, dueIn: 1800, from: now),
                token(.stagedApproval, "mission.step", valence: -0.2, dueIn: day, from: now),
            ], at: now),
            to: .empty
        ).ledger

        let toward = OrganismHorizonRegister.toward(in: ledger, at: now)
        #expect(toward?.label == "claude")
        #expect(toward?.sourceKind == .peerReply)
        #expect(toward?.valenceSign == 1)
        #expect(toward?.isOverdue == false)

        let dreaded = OrganismHorizonRegister.toward(
            in: apply(
                horizonSignal([token(.stagedApproval, "mission.step", valence: -0.2, dueIn: 60, from: now)], at: now),
                to: .empty
            ).ledger,
            at: now
        )
        #expect(dreaded?.valenceSign == -1)
    }

    @Test("a plan he spoke aloud becomes the thing she is toward")
    func committedPlanReachesToward() {
        // The consumer half of the live gap. `MemoryDueDateStamp` resolves
        // "tomorrow around nine" at write time and stamps `due_label`
        // "tomorrow 09:00"; the runtime offers that as a `statedPlan` source,
        // and this is what she is then facing. (The write half is pinned in
        // MemoryV2Tests — the two modules do not share a test target, which is
        // the layering working.)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = apply(
            horizonSignal([
                token(.statedPlan, "tomorrow 09:00", valence: 0.25, dueIn: 19 * 3600, from: now),
                token(.scheduledJob, "nativeagent-nightly-dream", valence: 0.35, dueIn: 3 * day, from: now),
            ], at: now),
            to: .empty
        ).ledger

        let toward = OrganismHorizonRegister.toward(in: ledger, at: now)
        #expect(toward?.sourceKind == .statedPlan)
        // Canonicalised on the way in — payload-free by construction, and the
        // word-level shape the capsule renders ("hopeful — tomorrow-09-00").
        #expect(toward?.label == "tomorrow-09-00")
        #expect(toward?.valenceSign == 1)
        #expect(toward?.isOverdue == false)
    }

    @Test("a plan whose moment has gone never opens a row")
    func pastDatedPlansAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = apply(
            horizonSignal([
                token(.statedPlan, "yesterday 09:00", valence: 0.25, dueIn: -26 * 3600, from: now),
            ], at: now),
            to: .empty
        ).ledger
        // An atom dated in the past is a record of something that already
        // happened. She was never looking toward it, so there is nothing to
        // anticipate and nothing to be let down by.
        #expect(horizonRows(ledger).isEmpty)
        #expect(OrganismHorizonRegister.toward(in: ledger, at: now) == nil)
    }

    @Test("toward is nil when nothing is open — silence, not a word")
    func towardIsNilWhenNothingIsOpen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OrganismHorizonRegister.toward(in: .empty, at: now) == nil)
    }

    @Test("a label can carry an identifier and nothing else")
    func labelsArePayloadFree() {
        #expect(OrganismHorizonRegister.canonicalLabel("Dinner with User, 8pm — the good place")
            == "dinner-with-user-8pm-the-good-place")
        #expect(OrganismHorizonRegister.canonicalLabel("   ") == "unknown")
        #expect(OrganismHorizonRegister.canonicalLabel(String(repeating: "a", count: 200)).count
            <= OrganismHorizonRegister.labelCharacterCap)
        // A label can never split its own token.
        #expect(!OrganismHorizonRegister.canonicalLabel("a|b").contains("|"))
    }
}

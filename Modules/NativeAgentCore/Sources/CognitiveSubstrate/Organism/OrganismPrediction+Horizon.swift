import Foundation
import PersistenceCore

extension OrganismPredictiveBody {
    // MARK: - Item 5: the horizon family

    /// The WHOLE consequence of a `.horizonRefresh` signal, and the only entry
    /// point the kernel uses for one.
    ///
    /// Deliberately not `applying(signal:…)`: that function is the ordinary
    /// somatic path and its caller pairs it with chemistry, plasticity, body
    /// schema, signal accounting and the resolution-felt drain. A refresh is
    /// none of those things. Here the register is refreshed and the horizon
    /// sweep runs — and nothing that has not been asked for.
    ///
    /// The sweep is horizon-only on purpose. Expiring OTHER kinds here would
    /// make a calendar read stamp misses on tool and provider expectations at a
    /// moment that has nothing to do with them; those keep expiring on the next
    /// real signal, exactly as before.
    public static func applyingHorizonRefresh(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState,
        at now: Date
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState) {
        var nextLedger = ledger
        var nextChemistry = chemicalState
        applyHorizonSources(signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        for id in nextLedger.predictions.keys.sorted() {
            guard var row = nextLedger.predictions[id],
                  row.horizon != nil,
                  row.status == .pending,
                  row.dueAt < now else { continue }
            // Never a miss — the shared transition says so, and says it once.
            _ = applyExpiryTransition(to: &row, at: now)
            nextLedger.predictions[id] = row
            nextLedger.expiredCount += 1
        }
        nextLedger.lastUpdatedAt = max(nextLedger.lastUpdatedAt ?? .distantPast, now)
        return (nextLedger, nextChemistry)
    }

    /// One refresh of the forward register from the COMPLETE current source
    /// set. Three things happen, in this order:
    ///
    ///   1. **Prune.** Horizon rows that already went terminal are removed. The
    ///      runtime has just read them out of the pre-signal ledger to announce
    ///      relief / disappointment / waiting; leaving them would announce the
    ///      same moment on every later refresh.
    ///   2. **Settle the absent.** A row whose source is GONE while its horizon
    ///      is still ahead is a thing that landed early — the approval was
    ///      given, the peer wrote back, he answered. That is the relief door.
    ///      A row whose horizon has already passed is left alone: the sweep
    ///      below owns it, and it becomes `waiting`.
    ///   3. **Refresh or mint the present.** An existing row keeps its identity
    ///      and takes the new due time and valence; a new source opens a row.
    ///
    /// Bounded: ≤`maximumOpen` open rows (overflow drops the FARTHEST — the
    /// nearest horizon is the one she is actually facing), ≤`maximumHorizon`
    /// out, and a due time already in the past never mints.
    ///
    /// Absent metadata ⇒ nothing happens at all. An EMPTY array is meaningful
    /// and different: it says "there are no sources right now", and settles or
    /// expires everything she was holding.
    private static func applyHorizonSources(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        guard case .array(let rawSources)? = signal.metadata[OrganismHorizonRegister.metadataKey] else {
            return
        }
        let now = signal.occurredAt

        // 1. Prune announced terminals.
        for row in OrganismHorizonRegister.settled(in: ledger) {
            ledger.predictions.removeValue(forKey: row.id)
        }

        // Which source kinds the composer could read COMPLETELY. A reader that
        // threw contributes zero tokens, which is indistinguishable at this
        // layer from "that source went away" — and "went away" is the relief
        // door. So absence is only ever read as an answer for a kind the
        // composer explicitly vouched for. An unreadable Desk does not tell her
        // her plans came true.
        var completeKinds: Set<OrganismHorizonSourceKind> = []
        if case .array(let rawComplete)? = signal.metadata[OrganismHorizonRegister.completeKindsKey] {
            for raw in rawComplete {
                guard case .string(let value) = raw,
                      let kind = OrganismHorizonSourceKind(rawValue: value) else { continue }
                completeKinds.insert(kind)
            }
        }

        // Decode. Two buckets, because "already overdue" is a real state and it
        // is NOT a new expectation:
        //   · MINTABLE — a horizon still ahead and inside the week. These open
        //     and refresh rows.
        //   · OVERDUE — a source that is still there but whose moment has
        //     passed. It refreshes a row she already holds (so the sweep can
        //     turn it into `waiting`) and it counts as PRESENT, so its absence
        //     is never mistaken for an answer. It never opens a new row: a
        //     source first seen already-late is a stale read, not a thing she
        //     was ever looking toward, and minting one would manufacture an
        //     anticipation she never had and then immediately break it.
        var mintable: [(id: String, horizon: OrganismHorizonExpectation, dueAt: Date)] = []
        var overdue: [(id: String, horizon: OrganismHorizonExpectation, dueAt: Date)] = []
        var seen: Set<String> = []
        for raw in rawSources {
            guard case .string(let token) = raw,
                  let source = OrganismHorizonRegister.decodeSource(token) else { continue }
            guard source.dueAt.timeIntervalSince(now) <= OrganismHorizonRegister.maximumHorizon
            else { continue }
            let id = OrganismHorizonRegister.rowID(
                sourceKind: source.sourceKind, label: source.label
            )
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let entry = (
                id: id,
                horizon: OrganismHorizonExpectation(
                    sourceKind: source.sourceKind,
                    label: source.label,
                    valence: source.valence
                ),
                dueAt: source.dueAt
            )
            if source.dueAt > now { mintable.append(entry) } else { overdue.append(entry) }
        }
        mintable.sort { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
        // The cap belongs to the things she can still look toward. An overdue
        // entry costs no slot — it is presence, not expectation.
        mintable = Array(mintable.prefix(OrganismHorizonRegister.maximumOpen))
        let present = Set(mintable.map(\.id)).union(overdue.map(\.id))

        // 2. Settle rows whose source is gone but whose horizon has not passed.
        //
        // Three ways a row can be absent from the offered set, and only ONE of
        // them is an answer:
        //   · the composer could not read that source  → leave it entirely;
        //   · it was crowded out of a full set          → evict, no feeling;
        //   · the source is genuinely gone              → it landed. Relief.
        let farthestOffered = mintable.last?.dueAt
        let setIsFull = mintable.count >= OrganismHorizonRegister.maximumOpen
        for row in OrganismHorizonRegister.open(in: ledger, at: now) where !present.contains(row.id) {
            guard row.dueAt > now else { continue }
            guard let kind = row.horizon?.sourceKind, completeKinds.contains(kind) else { continue }
            if setIsFull, let farthestOffered, row.dueAt > farthestOffered {
                ledger.predictions.removeValue(forKey: row.id)
                continue
            }
            settleHorizonExpectation(
                row, at: now, ledger: &ledger, chemicalState: &chemicalState
            )
        }

        // 3a. An overdue source only ever updates a row she already holds.
        for source in overdue {
            guard var existing = ledger.predictions[source.id],
                  existing.status == .pending,
                  now >= existing.lastUpdatedAt else { continue }
            existing.dueAt = source.dueAt
            existing.horizon = source.horizon
            existing.lastUpdatedAt = now
            ledger.predictions[source.id] = existing
        }

        // 3b. Refresh or mint.
        for source in mintable {
            if var existing = ledger.predictions[source.id], existing.status == .pending {
                guard now >= existing.lastUpdatedAt else { continue }
                existing.dueAt = source.dueAt
                existing.horizon = source.horizon
                existing.confidence = horizonConfidence(for: source.horizon)
                existing.uncertainty = horizonUncertainty(for: source.horizon)
                existing.lastUpdatedAt = now
                ledger.predictions[source.id] = existing
                continue
            }
            ledger.predictions[source.id] = OrganismPrediction(
                id: source.id,
                kind: .semanticExpectation,
                sourceOrgan: "\(OrganismHorizonRegister.sourceOrgan).\(source.horizon.label)",
                createdAt: now,
                dueAt: source.dueAt,
                confidence: horizonConfidence(for: source.horizon),
                uncertainty: horizonUncertainty(for: source.horizon),
                lastUpdatedAt: now,
                horizon: source.horizon
            )
        }

        // 4. The family's OWN cap, enforced on the ledger rather than trusted to
        // the offered set. Bounding the incoming tokens is not the same
        // guarantee: rows also survive from earlier refreshes, and a producer
        // that ignored the bound would otherwise grow the register. Overflow
        // drops the FARTHEST — the nearest horizon is the one she is facing —
        // and is an eviction, not an expiry: she stopped holding it, which is
        // not the same as having been wrong or having been answered.
        let openRows = OrganismHorizonRegister.open(in: ledger, at: now)
        if openRows.count > OrganismHorizonRegister.maximumOpen {
            for stale in openRows.suffix(openRows.count - OrganismHorizonRegister.maximumOpen) {
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }
    }

    /// How sure she is it will go the way she guesses. Anchored at even odds and
    /// leaned by the valence guess, so a thing she is looking forward to clears
    /// `OrganismResolutionFelt.disappointmentExpectationFloor` when it falls
    /// through, and a thing she dreads does not manufacture disappointment for
    /// having been right about it.
    private static func horizonConfidence(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 + 0.45 * horizon.valence)
    }

    private static func horizonUncertainty(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 - 0.25 * abs(horizon.valence))
    }

    /// A horizon that landed before its due time. The chemistry release is the
    /// SHARED satisfied effect (the relief door), but NO per-kind outcome is
    /// recorded: `.semanticExpectation`'s cumulative counts are the evidence
    /// behind "how do my claims land", and a peer writing back is not evidence
    /// about that. The felt half is composed by the runtime's horizon lane, not
    /// by `OrganismResolutionFelt` — see that file's exclusion.
    private static func settleHorizonExpectation(
        _ prediction: OrganismPrediction,
        at date: Date,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        var row = prediction
        // Size the exhale to the held breath, exactly as `satisfy` does — the
        // dread this row applied to the projection is the dread it releases.
        let bracing = min(
            1,
            OrganismProspectiveAffect.horizonContribution(row, at: date).dread
        )
        row.status = .satisfied
        row.confidence = OrganismBodyConfidence.clamp(row.confidence + 0.10)
        row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty - 0.10)
        row.evidenceCount += 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        ledger.satisfiedCount += 1
        applySatisfiedEffect(
            kind: .semanticExpectation,
            intensity: 0.4,
            bracing: bracing,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }
}

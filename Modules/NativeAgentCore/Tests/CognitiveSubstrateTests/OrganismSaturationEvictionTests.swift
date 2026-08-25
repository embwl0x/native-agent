import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger fence core.substrate.organism —
//   organism.persistenceLimits  (nodes 96 / edges 192 / predictions 96 /
//                                reflexes 64 / receipts 128 / signalCount 1e6 /
//                                decayHours 72)
//   organism.predictionLimits   (maximumPredictions 96)
//
// SATURATION-AS-NORMAL is the silent failure. The LIVE root
// (data/cognition/organism_state.json, read 2026-08-23) sits EXACTLY at every
// cap: nodes 96/96, edges 192/192, predictions 96/96, reflex candidates 64/64,
// observations 64/64. A collection permanently at 100% of cap is
// indistinguishable from one whose eviction stopped selecting correctly — the
// count looks identical either way. So these evals never assert a count alone;
// they assert the SELECTION ENVELOPE: what survives must dominate what was
// dropped under the code's own ordering, and no eviction may leave dangling
// references behind.
//
// Fixtures are shaped from the live root (violated-heavy prediction ledger,
// one retired reflex candidate holding a slot among active ones), not invented.

private let evictionNow = Date(timeIntervalSince1970: 1_766_000_000)

// MARK: - Field: nodes + edges

@Test
func persistedFieldEvictionKeepsTheMostSalientNodesAndDropsNoDanglingEdges() {
    let limits = OrganismPersistenceLimits()
    // 3x the node cap so eviction is genuinely exercised, with activations
    // deliberately NOT in insertion order (dictionary iteration must not decide).
    var nodes: [String: OrganismNode] = [:]
    for index in 0..<(limits.maximumPersistedNodes * 3) {
        let id = String(format: "node-%03d", index)
        // Interleave high/low so a "first N" bug cannot accidentally pass.
        let activation = Double((index * 37) % 289) / 289.0
        nodes[id] = OrganismNode(
            id: id,
            kind: .organ,
            label: id,
            activation: activation,
            charge: 1.0 - activation,
            lastActivatedAt: evictionNow.addingTimeInterval(-Double(index))
        )
    }
    // Edges over their own cap, every one referencing real nodes.
    var edges: [String: OrganismEdge] = [:]
    let ids = nodes.keys.sorted()
    for index in 0..<(limits.maximumPersistedEdges * 2) {
        let a = ids[index % ids.count]
        let b = ids[(index * 7 + 3) % ids.count]
        guard a != b else { continue }
        let edge = OrganismEdge(
            sourceID: a,
            targetID: b,
            weight: Double((index * 13) % 101) / 101.0,
            lastUpdatedAt: evictionNow.addingTimeInterval(-Double(index))
        )
        edges[edge.id] = edge
    }

    let state = OrganismPersistentState(
        savedAt: evictionNow.addingTimeInterval(-3_600),
        field: OrganismField(nodes: nodes, edges: edges),
        signalCount: 100
    )
    let decayed = state.decayed(at: evictionNow, limits: limits)

    // (1) Envelope, not an exact number: at or under cap.
    #expect(decayed.field.nodes.count <= limits.maximumPersistedNodes)
    #expect(decayed.field.edges.count <= limits.maximumPersistedEdges)
    // Saturated input ⇒ saturated output. If this ever drops below cap with a
    // 3x-over-cap input, eviction is over-deleting.
    #expect(decayed.field.nodes.count == limits.maximumPersistedNodes)

    // (2) SELECTION: every retained node must dominate every evicted node under
    // the persistence sort (activation desc, charge desc, id asc). Decay is a
    // uniform multiplier, so it preserves the ordering — comparing post-decay
    // values is legitimate.
    let retained = decayed.field.nodes
    let evictedIDs = Set(nodes.keys).subtracting(retained.keys)
    #expect(!evictedIDs.isEmpty, "nothing was evicted — the fixture is not over cap")

    func dominates(_ lhs: OrganismNode, _ rhs: OrganismNode) -> Bool {
        if lhs.activation != rhs.activation { return lhs.activation > rhs.activation }
        if lhs.charge != rhs.charge { return lhs.charge > rhs.charge }
        return lhs.id < rhs.id
    }
    // Re-derive what the evicted rows WOULD have looked like post-decay so the
    // comparison is apples to apples.
    let elapsedHours = 1.0
    let activationFactor = pow(0.82, elapsedHours)
    let chargeFactor = pow(0.90, elapsedHours)
    let evictedDecayed: [OrganismNode] = evictedIDs.compactMap { id in
        guard var node = nodes[id] else { return nil }
        node.activation = OrganismNode.clamp01(node.activation * activationFactor)
        node.charge = OrganismNode.clamp01(node.charge * chargeFactor)
        return node
    }
    let weakestRetained = retained.values.sorted(by: dominates).last!
    let strongestEvicted = evictedDecayed.sorted(by: dominates).first!
    #expect(
        dominates(weakestRetained, strongestEvicted),
        """
        eviction is no longer salience-shaped: kept \(weakestRetained.id) \
        (act \(weakestRetained.activation)) while dropping \(strongestEvicted.id) \
        (act \(strongestEvicted.activation))
        """
    )

    // (3) LIFECYCLE: no edge may outlive its endpoints. A dangling edge is a
    // leak that renders as an intact-looking field.
    for edge in decayed.field.edges.values {
        #expect(
            retained[edge.sourceID] != nil && retained[edge.targetID] != nil,
            "edge \(edge.id) survived node eviction with a missing endpoint"
        )
    }
}

// MARK: - Predictions

/// The named starvation mode: "if pending rows stop resolving, the cap fills
/// with stale pending rows and new expectations are evicted before they can ever
/// be satisfied." The guard is the overdue-pending → expired demotion that runs
/// BEFORE the cap sort. This fixture makes the stale rows the most RECENTLY
/// touched, so recency alone cannot save the live ones — only the demotion can.
@Test
func overduePendingPredictionsCannotStarveOutLiveExpectations() {
    let limits = OrganismPersistenceLimits()
    var predictions: [String: OrganismPrediction] = [:]

    // 120 overdue pending rows, touched one second ago (the newest of everything).
    for index in 0..<120 {
        let id = String(format: "stale-%03d", index)
        predictions[id] = OrganismPrediction(
            id: id,
            kind: .toolCompletion,
            sourceOrgan: "tool.stuck",
            createdAt: evictionNow.addingTimeInterval(-86_400),
            dueAt: evictionNow.addingTimeInterval(-3_600),   // overdue
            status: .pending,
            lastUpdatedAt: evictionNow.addingTimeInterval(-1)
        )
    }
    // 6 live expectations, not yet due, touched LESS recently than the stale ones.
    let liveIDs = (0..<6).map { String(format: "live-%03d", $0) }
    for id in liveIDs {
        predictions[id] = OrganismPrediction(
            id: id,
            kind: .providerCompletion,
            sourceOrgan: "provider.live",
            createdAt: evictionNow.addingTimeInterval(-1_200),
            dueAt: evictionNow.addingTimeInterval(3_600),    // still live
            status: .pending,
            lastUpdatedAt: evictionNow.addingTimeInterval(-1_000)
        )
    }
    // Violated-heavy tail, mirroring the live root (93 violated / 2 satisfied / 1 expired).
    for index in 0..<90 {
        let id = String(format: "violated-%03d", index)
        predictions[id] = OrganismPrediction(
            id: id,
            kind: .toolCompletion,
            sourceOrgan: "tool.past",
            createdAt: evictionNow.addingTimeInterval(-7_200),
            dueAt: evictionNow.addingTimeInterval(-7_000),
            status: .violated,
            lastUpdatedAt: evictionNow.addingTimeInterval(-500)
        )
    }

    let state = OrganismPersistentState(
        savedAt: evictionNow.addingTimeInterval(-3_600),
        predictionLedger: OrganismPredictionLedger(predictions: predictions),
        signalCount: 1
    )
    let decayed = state.decayed(at: evictionNow, limits: limits)
    let kept = decayed.predictionLedger.predictions

    #expect(kept.count <= limits.maximumPersistedPredictions)
    #expect(kept.count == limits.maximumPersistedPredictions, "a 216-row ledger should saturate the 96 cap")

    // THE TOOTH: every live, not-yet-due expectation survives, even though 120
    // stale rows were touched more recently.
    for id in liveIDs {
        #expect(
            kept[id] != nil,
            "live expectation \(id) was evicted by stale unresolved rows — new expectations can never be satisfied"
        )
    }
    // And the overdue rows were demoted, not silently kept as pending.
    let survivingStale = kept.values.filter { $0.id.hasPrefix("stale-") }
    #expect(
        survivingStale.allSatisfy { $0.status == .expired },
        "an overdue pending row survived still marked pending — the demotion did not run"
    )
}

/// The ordering envelope itself: the retained ledger is a prefix of the code's
/// own (status-rank desc, lastUpdatedAt desc, id asc) ordering — no lower-ranked
/// row may be kept while a higher-ranked one is dropped.
@Test
func predictionEvictionRetainsAStatusRankedPrefixNotAnArbitrarySubset() {
    let limits = OrganismPersistenceLimits()
    var predictions: [String: OrganismPrediction] = [:]
    let statuses: [OrganismPredictionStatus] = [.pending, .violated, .satisfied, .expired]
    for index in 0..<200 {
        let id = String(format: "p-%03d", index)
        predictions[id] = OrganismPrediction(
            id: id,
            kind: .workflowAdvance,
            sourceOrgan: "mixed",
            createdAt: evictionNow.addingTimeInterval(-9_000),
            dueAt: evictionNow.addingTimeInterval(9_000),  // all live: no demotion
            status: statuses[index % statuses.count],
            lastUpdatedAt: evictionNow.addingTimeInterval(-Double((index * 31) % 977))
        )
    }
    let state = OrganismPersistentState(
        savedAt: evictionNow.addingTimeInterval(-3_600),
        predictionLedger: OrganismPredictionLedger(predictions: predictions),
        signalCount: 1
    )
    let kept = state.decayed(at: evictionNow, limits: limits).predictionLedger.predictions
    #expect(kept.count == limits.maximumPersistedPredictions)

    func rank(_ status: OrganismPredictionStatus) -> Int {
        switch status {
        case .pending: return 4
        case .violated: return 3
        case .satisfied: return 2
        case .expired: return 1
        }
    }
    let evicted = predictions.values.filter { kept[$0.id] == nil }
    #expect(!evicted.isEmpty)
    let lowestKeptRank = kept.values.map { rank($0.status) }.min() ?? 0
    let highestEvictedRank = evicted.map { rank($0.status) }.max() ?? 0
    #expect(
        lowestKeptRank >= highestEvictedRank,
        "kept a rank-\(lowestKeptRank) row while evicting a rank-\(highestEvictedRank) row"
    )
}

// MARK: - Reflex candidates + receipts

/// The live root has a RETIRED candidate occupying one of the 64 slots. When the
/// queue is over cap, a retired candidate must never displace an active one —
/// otherwise the review queue silently fills with dead entries and the operator
/// panel (which renders only the first 4) can never drain it.
@Test
func retiredReflexCandidatesNeverDisplaceActiveOnesAtTheCap() {
    let limits = OrganismPersistenceLimits()
    var candidates: [String: OrganismReflexCandidate] = [:]
    // 40 retired candidates that are BETTER on every secondary key.
    for index in 0..<40 {
        let id = String(format: "retired-%03d", index)
        candidates[id] = OrganismReflexCandidate(
            id: id,
            pattern: "retired pattern \(index)",
            trustClass: .lowRisk,
            confidence: 0.99,
            reviewRequired: true,
            firstSeenAt: evictionNow.addingTimeInterval(-86_400),
            lastUpdatedAt: evictionNow.addingTimeInterval(-1),
            retiredAt: evictionNow.addingTimeInterval(-10)
        )
    }
    // 60 active candidates that are WORSE on every secondary key.
    let activeIDs = (0..<60).map { String(format: "active-%03d", $0) }
    for id in activeIDs {
        candidates[id] = OrganismReflexCandidate(
            id: id,
            pattern: "active \(id)",
            trustClass: .lowRisk,
            confidence: 0.01,
            reviewRequired: false,
            firstSeenAt: evictionNow.addingTimeInterval(-86_400),
            lastUpdatedAt: evictionNow.addingTimeInterval(-10_000)
        )
    }

    let state = OrganismPersistentState(
        savedAt: evictionNow.addingTimeInterval(-3_600),
        reflexState: OrganismReflexState(candidates: candidates),
        signalCount: 1
    )
    let kept = state.decayed(at: evictionNow, limits: limits).reflexState.candidates

    #expect(kept.count <= limits.maximumPersistedReflexes)
    for id in activeIDs {
        #expect(
            kept[id] != nil,
            "active candidate \(id) was evicted while retired candidates held slots"
        )
    }
}

/// Review receipts are the ONLY attributable record that a human reached in and
/// approved a reflex. The bound keeps the NEWEST — a prefix bug would silently
/// discard every recent decision while the count still reads 128.
@Test
func reflexReviewReceiptBoundKeepsTheNewestDecisionsNotTheOldest() {
    let limits = OrganismPersistenceLimits()
    let receipts: [OrganismReflexReviewReceipt] = (0..<200).map { index in
        OrganismReflexReviewReceipt(
            id: String(format: "receipt-%03d", index),
            candidateID: String(format: "cand-%03d", index),
            pattern: "pattern \(index)",
            trustClass: .lowRisk,
            decision: .approve,
            reviewedAt: evictionNow.addingTimeInterval(-Double(200 - index)),
            reviewedBy: "operator",
            source: "mac_observatory",
            evidenceCount: 3,
            successCount: 3,
            failureCount: 0,
            confidence: 0.7,
            autoActivationAllowed: true,
            permanentlyDeliberate: false
        )
    }
    let state = OrganismPersistentState(
        savedAt: evictionNow.addingTimeInterval(-3_600),
        reflexState: OrganismReflexState(reviewReceipts: receipts),
        signalCount: 1
    )
    let kept = state.decayed(at: evictionNow, limits: limits).reflexState.reviewReceipts

    #expect(kept.count == limits.maximumPersistedReflexReviewReceipts)
    #expect(kept.last?.id == receipts.last?.id, "the newest review receipt was dropped")
    // Chronology preserved: the retained window is contiguous and ends at "now".
    #expect(kept.first?.id == receipts[receipts.count - limits.maximumPersistedReflexReviewReceipts].id)
}

// MARK: - Scalar bounds

@Test
func signalCountIsBoundedAndDecayIsCappedAtTheDecayWindow() {
    let limits = OrganismPersistenceLimits()
    let hot = ChemicalState(
        warmth: 0.9, vigilance: 0.9, curiosity: 0.9, fatigue: 0.9,
        coherence: 0.9, agency: 0.9, tenderness: 0.9, confidence: 0.9,
        novelty: 0.9, urgency: 0.9
    )
    let base = OrganismPersistentState(
        savedAt: evictionNow,
        chemicalState: hot,
        signalCount: 5_000_000
    )

    // signalCount is bounded, not merely stored.
    let short = base.decayed(at: evictionNow.addingTimeInterval(3_600), limits: limits)
    #expect(short.signalCount <= limits.maximumSignalCount)
    #expect(short.signalCount == limits.maximumSignalCount)

    // Decay saturates at maximumDecayHours: a 72h gap and a 1000h gap must land
    // on the SAME chemistry. Otherwise a long-cold app decays unboundedly.
    let atCap = base.decayed(
        at: evictionNow.addingTimeInterval(limits.maximumDecayHours * 3_600),
        limits: limits
    )
    let farBeyond = base.decayed(at: evictionNow.addingTimeInterval(1_000 * 3_600), limits: limits)
    #expect(abs(atCap.chemicalState.vigilance - farBeyond.chemicalState.vigilance) < 1e-12)
    #expect(abs(atCap.chemicalState.warmth - farBeyond.chemicalState.warmth) < 1e-12)
    // Non-vacuous: a 1h gap is genuinely different from the capped one.
    #expect(abs(short.chemicalState.warmth - atCap.chemicalState.warmth) > 1e-6)
}

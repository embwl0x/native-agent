import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row
// `cognition.attentionProjection.replaceSubstrate`
// (Sources/NativeAgentApp/CognitiveAttentionResidentProjection.swift:28).
//
// Silent failure named in the ledger: "if a writer stops publishing, `read`
// keeps returning the last value until the 10-min unresolvedQuestion horizon,
// then returns partial signals forever with no error." This is the lock-backed
// handoff every turn reads to decide what Agent is attending to, and the only
// self-defence it has is the defensive expiry below. Nothing pinned it.
//
// Each test asserts a property of the READ envelope, not an internal:
//   1. the staleness horizon actually expires the open question (and does NOT
//      expire one inside the horizon) — the anti-stale tooth;
//   2. a publish with no clock (`substratePublishedAt` unset by construction)
//      can never resurrect a question;
//   3. the pursuit overlay outranks the substrate's own task/goal and clears
//      on blank input rather than leaving a stale intent resident;
//   4. an empty projection reads as nil — "not measured", never a fabricated
//      all-empty signal object that a caller would treat as measured-and-empty.
@Suite("Cognitive attention resident projection")
struct CognitiveAttentionResidentProjectionTests {
    private let horizon: TimeInterval = 10 * 60

    private func signals(question: String?) -> CognitiveAttentionSignals {
        CognitiveAttentionSignals(
            terms: ["context-flow": 0.8],
            unresolvedQuestion: question,
            activeTask: "substrate task",
            goal: "substrate goal",
            memoryActivation: ["rec-1": 0.5],
            workingMemoryRecordIDs: ["rec-1"]
        )
    }

    @Test("the open question survives inside the horizon and expires past it")
    func unresolvedQuestionExpiresAtTheHorizon() {
        let projection = CognitiveAttentionResidentProjection()
        let publishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        projection.replaceSubstrate(signals(question: "did the wave land?"), publishedAt: publishedAt)

        let fresh = projection.read(at: publishedAt.addingTimeInterval(horizon - 1))
        #expect(fresh?.unresolvedQuestion == "did the wave land?")

        let stale = projection.read(at: publishedAt.addingTimeInterval(horizon + 1))
        #expect(
            stale?.unresolvedQuestion == nil,
            "a writer that stopped publishing must not keep an open question resident forever"
        )
        // Expiry is SURGICAL: the rest of the handoff is still the last known
        // truth, so a stale question can't blank her whole attention lane.
        #expect(stale?.activeTask == "substrate task")
        #expect(stale?.terms.isEmpty == false)
    }

    @Test("a read at a clock BEFORE the publish never resurrects the question")
    func negativeAgeIsRejected() {
        let projection = CognitiveAttentionResidentProjection()
        let publishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        projection.replaceSubstrate(signals(question: "still open?"), publishedAt: publishedAt)

        let backwards = projection.read(at: publishedAt.addingTimeInterval(-30))
        #expect(
            backwards?.unresolvedQuestion == nil,
            "a backwards clock step must fail closed, not read as freshly published"
        )
    }

    @Test("the pursuit overlay outranks the substrate task/goal and clears on blank")
    func pursuitOverlayOutranksAndClears() {
        let projection = CognitiveAttentionResidentProjection()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        projection.replaceSubstrate(signals(question: nil), publishedAt: now)

        #expect(projection.read(at: now)?.activeTask == "substrate task")

        projection.replacePursuit(activeTask: "  close the eval fence  ", goal: "  ship wave A  ")
        let withPursuit = projection.read(at: now)
        #expect(withPursuit?.activeTask == "close the eval fence")
        #expect(withPursuit?.goal == "ship wave A")

        // A half-empty pursuit is NOT a pursuit: publishing one must clear the
        // overlay, not strand the previous intent as resident state.
        projection.replacePursuit(activeTask: "still working", goal: "   ")
        let cleared = projection.read(at: now)
        #expect(cleared?.activeTask == "substrate task")
        #expect(cleared?.goal == "substrate goal")
    }

    @Test("predicted tool groups are bounded and deterministic")
    func predictedToolGroupsAreCapped() {
        let projection = CognitiveAttentionResidentProjection()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let groups = Set((0..<20).map { String(format: "group-%02d", $0) })
        projection.replacePredictedToolGroups(groups)

        let published = projection.read(at: now)?.predictedToolGroups
        #expect(published?.count == 8, "an unbounded group set would thrash the packet fingerprint")
        // Deterministic keep-order: sorted prefix, so the same input always
        // produces the same eight.
        #expect(published == Set(groups.sorted().prefix(8)))
    }

    @Test("an empty projection reads as nil, never a fabricated empty signal")
    func emptyProjectionReadsAsNil() {
        let projection = CognitiveAttentionResidentProjection()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(projection.read(at: now) == nil)

        projection.replaceSubstrate(signals(question: nil), publishedAt: now)
        #expect(projection.read(at: now) != nil)

        // The writer withdrawing must read as "nothing measured" — a non-nil
        // all-empty object is the silent-zero shape a caller would render as a
        // healthy, genuinely empty attention lane.
        projection.replaceSubstrate(nil, publishedAt: now)
        #expect(projection.read(at: now) == nil)
    }
}

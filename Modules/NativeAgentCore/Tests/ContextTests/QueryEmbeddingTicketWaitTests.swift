import Foundation
import Testing
@testable import Context

// Best-agent sweep R4 A5(a). TurnEngine used to sample the query-embedding
// ticket with `valueIfReady` and never wait, so a still-warming MiniLM zeroed
// the semantic term for the whole of turn 1. The wait added here must be
// BOUNDED: a never-ready ticket returns nil promptly rather than hanging.
@Suite("Query embedding ticket bounded wait")
struct QueryEmbeddingTicketWaitTests {

    @Test func alreadyPublishedValueReturnsImmediately() async {
        let ticket = ContextQueryEmbeddingTicket()
        ticket.publish([1, 0, 0], modelFingerprint: "minilm-test")
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await ticket.value(waitingUpTo: 5_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(value?.values == [1, 0, 0])
        #expect(elapsed < 500_000_000, "a ready ticket must not wait")
    }

    @Test func neverReadyTicketTimesOutAndDoesNotHang() async {
        // The "never-ready fake": nothing ever publishes.
        let ticket = ContextQueryEmbeddingTicket()
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await ticket.value(waitingUpTo: 200_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(value == nil)
        #expect(elapsed >= 150_000_000, "returned before the timeout elapsed")
        #expect(elapsed < 30_000_000_000, "wait was not bounded (30s ceiling proves the timeout fired; tight wall-clock bounds flake under full-suite core saturation)")
    }

    @Test func lateArrivalResumesTheWaiterBeforeTheTimeout() async {
        let ticket = ContextQueryEmbeddingTicket()
        let publisher = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            ticket.publish([0, 1, 0], modelFingerprint: "minilm-warm")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await ticket.value(waitingUpTo: 60_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        await publisher.value
        #expect(value?.values == [0, 1, 0])
        #expect(value?.modelFingerprint == "minilm-warm")
        // Resumed on publish, not after sitting out the timeout window. The
        // bound must sit far BELOW the timeout to prove early resume (review
        // non-blocking 2026-08-06), and far ABOVE scheduler noise to survive
        // a saturated full-suite run (observed 4.7s starvation). 60s window
        // with a 30s bound gives both margins.
        #expect(elapsed < 30_000_000_000, "late arrival must resume on publish, not sit out the 60s timeout")
    }

    @Test func zeroTimeoutDegradesToTheOldSampleBehavior() async {
        let ticket = ContextQueryEmbeddingTicket()
        #expect(await ticket.value(waitingUpTo: 0) == nil)
        ticket.publish([1, 1], modelFingerprint: "fp")
        #expect(await ticket.value(waitingUpTo: 0)?.values == [1, 1])
    }

    @Test func concurrentWaitersAllResumeExactlyOnce() async {
        let ticket = ContextQueryEmbeddingTicket()
        async let a = ticket.value(waitingUpTo: 4_000_000_000)
        async let b = ticket.value(waitingUpTo: 4_000_000_000)
        async let c = ticket.value(waitingUpTo: 4_000_000_000)
        try? await Task.sleep(nanoseconds: 40_000_000)
        ticket.publish([2, 0], modelFingerprint: "fp")
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0?.values == [2, 0] })
    }
}

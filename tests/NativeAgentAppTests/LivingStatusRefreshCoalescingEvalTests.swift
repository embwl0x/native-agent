import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / logic.livingStatus.refreshCoalescing

@Suite("Living Status refresh coalescing")
struct LivingStatusRefreshCoalescingEvalTests {
    @Test("reissues during every in-flight pass collapse to one trailing refresh and terminate")
    func sustainedRequestPressureIsBounded() {
        var coalescer = LivingStatusRefreshCoalescer()
        let started = coalescer.requestRefresh()
        #expect(started)

        var refreshOnceInvocations = 0
        while coalescer.isRefreshing {
            refreshOnceInvocations += 1
            // Simulate a noisy file watcher and cognition stream both asking
            // again while every production refreshOnce pass is in flight.
            for _ in 0..<32 {
                let coalesced = coalescer.requestRefresh()
                #expect(!coalesced)
            }
            let needsTrailingPass = coalescer.completePass()
            if !needsTrailingPass { break }
        }

        #expect(refreshOnceInvocations == 2,
                "one initial pass plus at most one trailing pass may run")
        #expect(!coalescer.isRefreshing)
        #expect(!coalescer.trailingPassQueued)
        #expect(!coalescer.trailingPassConsumed)
    }

    @Test("a quiet refresh ends after one pass and a later edge starts a fresh episode")
    func quietAndLaterRefreshEpisodesRemainDistinct() {
        var coalescer = LivingStatusRefreshCoalescer()
        let firstStarted = coalescer.requestRefresh()
        #expect(firstStarted)
        let firstCompleted = coalescer.completePass()
        #expect(!firstCompleted)
        #expect(!coalescer.isRefreshing)

        let secondStarted = coalescer.requestRefresh()
        #expect(secondStarted,
                "an edge after the bounded episode must still refresh current state")
        let secondCompleted = coalescer.completePass()
        #expect(!secondCompleted)
        #expect(!coalescer.isRefreshing)
    }
}

import Testing
@testable import NativeAgentApp

// app.chat / ui.detached.resizeRepin
//
// The geometry callback is intentionally thin: AppKit/SwiftUI owns the live
// scroll proxy, while this evaluation drives the same production decision
// boundary through a full resize-burst sequence. The adverse rows prevent a
// stale task, a history reader, or a closed panel from being snapped down.
@Suite("Detached chat resize re-pin")
struct DetachedChatResizeRepinTests {
    @Test("only a bottom-pinned, current resize settle re-pins")
    func resizeBurstRepinsOnlyTheLiveBottomPinnedPanel() {
        // First tick captures the user's pre-reflow position.
        #expect(DetachedChatResizeRepin.shouldSnapshotBottom(hasPendingSettle: false))
        let firstToken = 41
        let wasAtBottom = true

        // Further ticks are one burst, so they preserve that first snapshot.
        #expect(!DetachedChatResizeRepin.shouldSnapshotBottom(hasPendingSettle: true))
        let latestToken = 42
        #expect(!DetachedChatResizeRepin.shouldRepin(
            settledToken: firstToken,
            currentToken: latestToken,
            wasAtBottom: wasAtBottom,
            isCancelled: false
        ))
        #expect(DetachedChatResizeRepin.shouldRepin(
            settledToken: latestToken,
            currentToken: latestToken,
            wasAtBottom: wasAtBottom,
            isCancelled: false
        ))

        // A history reader keeps their position, and a cancelled close may
        // never perform a late proxy scroll even when the old sentinel said
        // they were at bottom.
        #expect(!DetachedChatResizeRepin.shouldRepin(
            settledToken: latestToken,
            currentToken: latestToken,
            wasAtBottom: false,
            isCancelled: false
        ))
        #expect(!DetachedChatResizeRepin.shouldRepin(
            settledToken: latestToken,
            currentToken: latestToken,
            wasAtBottom: true,
            isCancelled: true
        ))
    }
}

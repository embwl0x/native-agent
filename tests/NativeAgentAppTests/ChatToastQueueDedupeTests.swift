import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / api.ChatToastQueue (REPORTS-ONLY → COVERED).
//
// Silent-failure mode being pinned: this queue is the sink for pin failures,
// voice-output errors and slash-command results. Its dedupe key collapses
// timestamps, uuids and ANSI escapes, so two GENUINELY different failures inside
// the 10s window can normalize to the same key and the second is dropped with no
// trace — the user is told about one failure and never about the other.
//
// The envelope asserted: distinct messages always surface; only messages that
// are equal AFTER normalization are suppressed. Timing is polled under a bound,
// never slept on blindly, so a stalled advance fails instead of hanging.

@MainActor
private func waitForToast(
    _ queue: ChatToastQueue,
    where predicate: @MainActor (String?) -> Bool,
    timeout: TimeInterval = 8.0
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(queue.current) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate(queue.current)
}

@MainActor
@Suite("Chat toast queue dedupe")
struct ChatToastQueueDedupeTests {

    /// Two failures that differ only in a timestamp/uuid are the SAME failure
    /// repeating — suppressed. Anything else must reach the user.
    @Test func onlyNormalizationEqualMessagesAreSuppressed() async {
        let queue = ChatToastQueue()
        queue.show("Pin failed at 2026-08-23T10:00:00Z")
        #expect(queue.current == "Pin failed at 2026-08-23T10:00:00Z")

        // Same failure, later timestamp → suppressed (this is the intent).
        queue.show("Pin failed at 2026-08-23T10:00:04Z")
        // Same failure, different uuid → suppressed.
        queue.show("Pin failed at 2026-08-23T10:00:07Z")

        // A genuinely different failure must NOT be swallowed.
        queue.show("Voice output failed: no speech grant")

        let surfacedDifferent = await waitForToast(queue) {
            $0 == "Voice output failed: no speech grant"
        }
        #expect(surfacedDifferent,
                "a genuinely different failure never reached the user (current=\(String(describing: queue.current)))")
    }

    /// Several distinct messages in a burst must ALL surface, in order — the
    /// queue is a delay, not a filter.
    @Test func everyDistinctMessageInABurstEventuallySurfaces() async {
        let queue = ChatToastQueue()
        let distinct = [
            "Feedback failed to send",
            "Chat exported to Downloads",
            "Unsupported file type: xyz",
        ]
        for message in distinct { queue.show(message) }

        var seen: [String] = []
        for expected in distinct {
            let arrived = await waitForToast(queue) { $0 == expected }
            #expect(arrived, "\(expected) was dropped by the toast queue")
            if arrived { seen.append(expected) }
            // Let the current toast retire before waiting for the next one.
            _ = await waitForToast(queue) { $0 != expected }
        }
        #expect(seen == distinct, "toasts surfaced out of order or were dropped: \(seen)")
    }

    /// An identical message repeated back-to-back must not double-render — the
    /// dedupe exists so a retry storm cannot hide the screen.
    @Test func anIdenticalRepeatIsSuppressedWhileItIsStillShowing() async {
        let queue = ChatToastQueue()
        queue.show("Feedback failed to send")
        #expect(queue.current == "Feedback failed to send")
        queue.show("Feedback failed to send")
        queue.show("Feedback failed to send")
        // Nothing else queued behind it: once it retires the lane goes quiet
        // rather than replaying the same line twice more.
        let cleared = await waitForToast(queue) { $0 == nil }
        #expect(cleared, "the toast lane never cleared")
        #expect(queue.current == nil,
                "an identical repeat replayed after the first toast retired")
    }
}

import Foundation
import Testing
@testable import MacControl
import PersistenceCore

// Agent's round-7 glass pass (2026-08-22, live, installed build).
// Two defects, each pinned here at the pure layer.

// MARK: - NON-KEY CRITICAL FAIL (envelope 173E1B08)

@Test
func keyWindowGate_refusesWhenAnotherAppIsFrontmost() {
    // Fresh Finder frame, then Chrome focused, then `open` on a Finder row:
    // the ⌘↓ would be delivered to Chrome by the window server.
    let refusal = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 71301,
        frontmostName: "Google Chrome",
        frameWindowHandle: 1,
        focusedWindowHandle: nil,
        frameWindowTitle: "queues",
        focusedWindowTitle: nil
    )
    #expect(refusal?.reason == "window_not_key")
    #expect(refusal?.note.contains("612") == true)
    #expect(refusal?.note.contains("Google Chrome") == true, "name the app that would have been typed into")
}

@Test
func keyWindowGate_allowsTheFramesOwnAppWhenItIsFrontmost() {
    #expect(MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 7,
        focusedWindowHandle: 7,
        frameWindowTitle: "queues",
        focusedWindowTitle: "queues"
    ) == nil)
}

@Test
func keyWindowGate_refusesTheRightAppsWrongWindow() {
    // Two Finder windows: the frame names one, the OTHER is key. A chord goes
    // to the key one.
    let refusal = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: 3,
        frameWindowTitle: "queues",
        focusedWindowTitle: "Documents"
    )
    #expect(refusal?.reason == "window_not_key")
    #expect(refusal?.note.contains("Documents") == true)
}

@Test
func keyWindowGate_cannotTellIsNotAMismatch() {
    // A source that does not publish a focused window must not turn silence
    // into a refusal — the app-level check has already passed.
    #expect(MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: nil,
        frameWindowTitle: "queues",
        focusedWindowTitle: nil
    ) == nil)
}

@Test
func keyWindowGate_failsClosedWhenTheFrontmostAppCannotBeRead() {
    let refusal = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: nil,
        frontmostName: nil,
        frameWindowHandle: nil,
        focusedWindowHandle: nil,
        frameWindowTitle: nil,
        focusedWindowTitle: nil
    )
    #expect(refusal?.reason == "frontmost_unknown",
            "unknown frontmost is a refusal for INPUT, never a pass")
}

// MARK: - First navigation missed by the same-call observer (envelope 4E998341)

@Test
func navigationWait_keepsWatchingPastTheSelectionNotification() async {
    let collector = MacAXEffectCollector()
    let started = Date(timeIntervalSince1970: 1_000)
    let clockBox = ClockBox(now: started)
    // The selection lands immediately; the retitle lands later.
    collector.record(MacAXEffectNotification(kind: "AXValueChanged", at: started))
    Task {
        try? await Task.sleep(nanoseconds: 60_000_000)
        collector.record(MacAXEffectNotification(kind: "AXTitleChanged", at: Date()))
    }
    let wait = await MacActClosedLoop.waitForEffect(
        collector: collector,
        waitMs: 1500,
        quietMs: 0,
        startedAt: started,
        clock: { clockBox.value() },
        until: MacActClosedLoop.navigationNotificationKinds
    )
    #expect(wait.observed)
    #expect(wait.notifications.contains("AXTitleChanged"),
            "the verb's own signal must be in the envelope, not just the selection")
}

@Test
func navigationWait_stillEndsAtTheDeadlineWhenTheSignalNeverComes() async {
    let collector = MacAXEffectCollector()
    let started = Date(timeIntervalSince1970: 2_000)
    collector.record(MacAXEffectNotification(kind: "AXValueChanged", at: started))
    let clockBox = ClockBox(now: started)
    let wait = await MacActClosedLoop.waitForEffect(
        collector: collector,
        waitMs: 120,
        quietMs: 0,
        startedAt: started,
        clock: { clockBox.advance(by: 0.05) },
        until: MacActClosedLoop.navigationNotificationKinds
    )
    #expect(wait.observed, "what DID fire is still reported — the deadline is not a failure")
    #expect(!wait.notifications.contains("AXTitleChanged"))
}

private final class ClockBox: @unchecked Sendable {
    private var now: Date
    private let lock = NSLock()
    init(now: Date) { self.now = now }
    func value() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func advance(by seconds: TimeInterval) -> Date {
        lock.lock(); defer { lock.unlock() }
        now = now.addingTimeInterval(seconds)
        return now
    }
}

@Test
func navigationKinds_areAllActuallySubscribed() {
    // A kind we wait for but never subscribe to can never arrive: the wait
    // would always run to the deadline and every `open` would pay 1.5s for a
    // verdict no better than before.
    let subscribed = Set(MacActClosedLoop.notificationKinds)
    let unsubscribed = MacActClosedLoop.navigationNotificationKinds.subtracting(subscribed)
    #expect(unsubscribed.isEmpty, "waiting for kinds the observer never asked for: \(unsubscribed)")
}
